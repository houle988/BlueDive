import SwiftUI
import SwiftData
import WidgetKit

// MARK: - DiveSortOrder

enum DiveSortOrder: String, CaseIterable, Identifiable {
    case dateDesc       = "dateDesc"
    case dateAsc        = "dateAsc"
    case depthDesc      = "depthDesc"
    case durationDesc   = "durationDesc"
    case diveNumberDesc = "diveNumberDesc"
    case diveNumberAsc  = "diveNumberAsc"

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .dateDesc:       return "Date ↓"
        case .dateAsc:        return "Date ↑"
        case .depthDesc:      return "Depth ↓"
        case .durationDesc:   return "Duration ↓"
        case .diveNumberDesc: return "Dive # ↓"
        case .diveNumberAsc:  return "Dive # ↑"
        }
    }
}

// MARK: - DiveStore

@MainActor
@Observable
final class DiveStore {

    // MARK: - Filter / Search / Sort State
    var searchText: String = ""
    var showFilterSheet: Bool = false
    var filterYear: Int? = nil
    var filterYearNegate: Bool = false
    var filterGasType: String? = nil
    var filterGasTypeNegate: Bool = false
    var filterMinDepth: Double = 0
    var filterMaxDepth: Double = 0
    var filterMinRating: Int = 0
    var filterCountry: String? = nil
    var filterCountryNegate: Bool = false
    var filterDiveType: String? = nil
    var filterDiveTypeNegate: Bool = false
    var filterTag: String? = nil
    var filterMarineLife: [String] = []
    var filterMarineLifeMode: FilterMarineLifeMode = .any
    var sortOrder: DiveSortOrder = .dateDesc

    // MARK: - Derived / Cached State
    private(set) var dives: [Dive] = []
    private(set) var diveIndexLookup: [UUID: Int] = [:]
    private(set) var cachedFilteredDives: [Dive] = []
    private(set) var cachedShowGrouped: Bool = false
    private(set) var cachedGroupedDives: [(key: String, value: [Dive])] = []
    private(set) var cachedUniqueDivers: [String] = []
    private(set) var cachedHasUnnamedDives: Bool = false
    private(set) var cachedWidgetFingerprint: Int = 0
    private(set) var hasCacheBuilt: Bool = false
    private(set) var cachedDivesWithFish: Set<UUID> = []
    private(set) var cachedDivesWithPhotos: Set<UUID> = []
    private var lastPhotoSweepDiveIDs: Set<UUID> = []
    private(set) var cachedAvailableYears: [Int] = []
    private(set) var cachedAvailableGasTypes: [String] = []
    private(set) var cachedAvailableCountries: [String] = []
    private(set) var cachedAvailableDiveTypes: [String] = []
    private(set) var cachedAvailableTags: [String] = []
    private(set) var cachedAvailableMarineLife: [String] = []
    private var cachedInsurances: [DivingInsurance] = []
    private var cachedMarineSights: [MarineSight] = []
    private var cachedSelectedDiver: String = ""

    // MARK: - Summary Cache
    private(set) var cachedSummaries: [DiveSummary] = []
    private(set) var cachedFilteredSummaries: [DiveSummary] = []
    private(set) var cachedGroupedSummaries: [(key: String, value: [DiveSummary])] = []
    private(set) var diveByID: [UUID: Dive] = [:]
    private var fishNamesByID: [UUID: [String]] = [:]

    // MARK: - Background Tasks
    private var searchDebounceTask: Task<Void, Never>?
    private var aggregationTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?

    // MARK: - Computed Properties

    var activeFilterCount: Int {
        var count = 0
        if filterYear != nil                        { count += 1 }
        if filterGasType != nil                     { count += 1 }
        if filterMinDepth > 0 || filterMaxDepth > 0 { count += 1 }
        if filterMinRating > 0                      { count += 1 }
        if filterCountry != nil                     { count += 1 }
        if filterDiveType != nil                    { count += 1 }
        if filterTag != nil                         { count += 1 }
        if !filterMarineLife.isEmpty                { count += 1 }
        return count
    }

    // MARK: - Filter Reset

    func resetFilters() {
        filterYear           = nil
        filterYearNegate     = false
        filterGasType        = nil
        filterGasTypeNegate  = false
        filterMinDepth       = 0
        filterMaxDepth       = 0
        filterMinRating      = 0
        filterCountry        = nil
        filterCountryNegate  = false
        filterDiveType       = nil
        filterDiveTypeNegate = false
        filterTag            = nil
        filterMarineLife     = []
        filterMarineLifeMode = .any
        sortOrder            = .dateDesc
    }

    // MARK: - Commit

    enum DiveChangeScope {
        case list       // timestamp/diverName/diveNumber change — full rebuild, updates widget fingerprint
        case rowBadges  // photo/fish add/remove — only refreshes badge sets
        case rowFields  // site/conditions/gas save — only re-filters/re-sorts
        case nothing
    }

    func commit(_ dive: Dive, affects scope: DiveChangeScope) {
        switch scope {
        case .list:
            // Bypass the debounce so a timestamp/depth/dive-number edit reorders the list
            // immediately. scheduleRebuild(force:true) is cancelled within its 50ms window
            // by the @Query re-delivery that fires force:false — which then short-circuits
            // on matching IDs and never runs, leaving the list in the wrong order.
            rebuildTask?.cancel()
            rebuildTask = nil
            let sortedDives = dives.sorted { $0.timestamp > $1.timestamp }
            rebuildDerivedDiveState(dives: sortedDives, allInsurances: cachedInsurances,
                                    allMarineSights: cachedMarineSights,
                                    selectedDiver: cachedSelectedDiver)
        case .rowBadges:
            refreshBadgeSets(for: dive.id, in: dives, showFilterSheet: showFilterSheet, selectedDiver: cachedSelectedDiver)
        case .rowFields:
            // Patch the one affected DiveSummary in-place, preserving badge state.
            if let idx = cachedSummaries.firstIndex(where: { $0.id == dive.id }) {
                var patched = DiveSummary(from: dive)
                patched.hasFish       = cachedSummaries[idx].hasFish
                patched.hasPhotos     = cachedSummaries[idx].hasPhotos
                patched.seenFishNames = cachedSummaries[idx].seenFishNames
                cachedSummaries[idx]  = patched
            }
            // Full re-filter only when an active filter could change this dive's membership.
            let filtersAffectMembership = !searchText.isEmpty
                || filterCountry  != nil || filterGasType  != nil
                || filterDiveType != nil || filterTag       != nil
                || filterMinDepth  > 0  || filterMaxDepth   > 0
                || filterMinRating > 0  || !filterMarineLife.isEmpty
            if filtersAffectMembership {
                rebuildFilteredDives(dives: dives, selectedDiver: cachedSelectedDiver)
            } else {
                // Fast path: re-derive filtered summary caches from the patched cachedSummaries
                // without an O(n) filter pass over all dives.
                let summaryByID = Dictionary(cachedSummaries.map { ($0.id, $0) },
                                             uniquingKeysWith: { f, _ in f })
                cachedFilteredSummaries = cachedFilteredDives.compactMap { summaryByID[$0.id] }
                cachedGroupedSummaries  = cachedGroupedDives.map { group in
                    (key: group.key, value: group.value.compactMap { summaryByID[$0.id] })
                }
            }
        case .nothing:
            break
        }
    }

    func commitListRebuild() {
        // Same synchronous bypass as commit(.list) — avoids the debounce-cancellation race
        // where a @Query re-delivery kills the force:true task before it runs.
        rebuildTask?.cancel()
        rebuildTask = nil
        let sortedDives = dives.sorted { $0.timestamp > $1.timestamp }
        rebuildDerivedDiveState(dives: sortedDives, allInsurances: cachedInsurances,
                                allMarineSights: cachedMarineSights,
                                selectedDiver: cachedSelectedDiver)
    }

    // Patches surfaceInterval in all three summary caches without a full rebuild.
    // Called on the MainActor from recalcSurfaceIntervalsInBackground after the
    // background context's recalculation completes — eliminates the main-context
    // merge race by delivering computed values directly rather than waiting for
    // @Query to re-deliver.
    func commitSurfaceIntervals(_ updates: [UUID: String]) {
        for idx in cachedSummaries.indices {
            if let si = updates[cachedSummaries[idx].id] {
                cachedSummaries[idx].surfaceInterval = si
            }
        }
        // Rebuild derived caches in a single atomic assignment each instead of nested in-place
        // mutations. Multiple element-level mutations on cachedGroupedSummaries fire rapid
        // @Observable notifications that cause Section(isExpanded:) to drop section headers
        // in the .sidebar list on iPad/Mac where the list is always visible.
        let summaryByID = Dictionary(cachedSummaries.map { ($0.id, $0) }, uniquingKeysWith: { f, _ in f })
        cachedFilteredSummaries = cachedFilteredDives.compactMap { summaryByID[$0.id] }
        cachedGroupedSummaries = cachedGroupedDives.map { group in
            (key: group.key, value: group.value.compactMap { summaryByID[$0.id] })
        }
    }

    // Spawns a background task that recalculates surface intervals for the diver
    // group(s) affected by an edit, then patches cachedSummaries via
    // commitSurfaceIntervals on the MainActor. Recalculates newDiverName's group,
    // and additionally originalDiverName's group when the two differ (a diver move).
    // For a timestamp-only edit, pass the same name for both parameters to recalc
    // that single diver's sequence. Must be called after modelContext.save() so the
    // background context reads the already-persisted state.
    func recalcSurfaceIntervalsInBackground(
        container: ModelContainer,
        newDiverName: String,
        originalDiverName: String
    ) {
        Task.detached(priority: .utility) { [weak self] in
            let bgContext = ModelContext(container)
            var updates = Dive.recalculateSurfaceIntervals(in: bgContext, diverName: newDiverName)
            if newDiverName != originalDiverName {
                let extra = Dive.recalculateSurfaceIntervals(in: bgContext, diverName: originalDiverName)
                updates.merge(extra) { _, new in new }
            }
            let finalUpdates = updates
            await MainActor.run { [weak self] in
                self?.commitSurfaceIntervals(finalUpdates)
            }
        }
    }

    // MARK: - Pipeline

    // Coalesces rapid-fire triggers into a single rebuild after a 50ms quiet period.
    // When force=false, skips the rebuild if dive membership is unchanged — this suppresses
    // spurious @Query re-deliveries that fire when edit sheets open/close without modifying data.
    // force=true is required when dive IDs are stable but data changed (field-level saves, insurance changes).
    func scheduleRebuild(
        dives: [Dive],
        allInsurances: [DivingInsurance],
        allMarineSights: [MarineSight],
        selectedDiver: String,
        force: Bool = false
    ) {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            if !force {
                let currentIDs = Set(dives.map { $0.id })
                guard currentIDs != self.lastPhotoSweepDiveIDs else { return }
            }
            self.rebuildDerivedDiveState(dives: dives, allInsurances: allInsurances, allMarineSights: allMarineSights, selectedDiver: selectedDiver)
        }
    }

    // Debounce-aware search rebuild (150ms quiet period).
    func scheduleSearchRebuild(dives: [Dive], selectedDiver: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver)
        }
    }

    func rebuildDerivedDiveState(
        dives: [Dive],
        allInsurances: [DivingInsurance],
        allMarineSights: [MarineSight],
        selectedDiver: String
    ) {
        self.dives = dives
        self.cachedInsurances = allInsurances
        self.cachedSelectedDiver = selectedDiver
        self.cachedMarineSights = allMarineSights
        // Phase 1 — Fast synchronous work on MainActor. Must complete before returning
        // so callers see a consistent index and filtered list immediately.
        cachedUniqueDivers = DiverFilter.uniqueDivers(in: dives, insurances: allInsurances)
        cachedHasUnnamedDives = dives.contains { $0.diverName.trimmingCharacters(in: .whitespaces).isEmpty }

        // diveIndexLookup maps dive.id → position in the timestamp-sorted @Query array. A timestamp
        // edit reorders the array without changing IDs, so this must be rebuilt on every pass (not
        // just on membership change) to keep positional dive numbers accurate.
        diveIndexLookup = Dictionary(
            dives.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // photosData is @Attribute(.externalStorage) and seenFish is a to-many relationship;
        // both are swept only when dive membership changes (add/delete). In-place edits to
        // photos flow through refreshBadgeSets(for:) via commit(_:affects: .rowBadges).
        let currentDiveIDs = Set(dives.map { $0.id })
        let membershipChanged = currentDiveIDs != lastPhotoSweepDiveIDs
        if membershipChanged {
            cachedDivesWithPhotos = Set(dives.filter { !($0.photosData?.isEmpty ?? true) }.map { $0.id })
            lastPhotoSweepDiveIDs = currentDiveIDs
        }

        // Build DiveSummary array before rebuildFilteredDives so the summary lookup has data.
        // seenFish is only faulted when dive membership changed to avoid up to 3000 individual
        // SQLite relationship faults on the MainActor for every field-level save.
        if membershipChanged {
            fishNamesByID = [:]
            for sight in allMarineSights {
                guard let diveID = sight.dive?.id else { continue }
                let name = sight.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                fishNamesByID[diveID, default: []].append(name)
            }
            cachedDivesWithFish = Set(fishNamesByID.filter { !$0.value.isEmpty }.map { $0.key })
        }

        cachedSummaries = dives.map { dive in
            var s = DiveSummary(from: dive)
            s.hasFish = cachedDivesWithFish.contains(dive.id)
            s.hasPhotos = cachedDivesWithPhotos.contains(dive.id)
            s.seenFishNames = fishNamesByID[dive.id] ?? []
            return s
        }

        // The chronologically oldest dive per diver has no preceding dive, so its surface
        // interval is definitionally zero. Imported dives may carry a stale value from the
        // source file; clear it here so the badge is never shown for the first dive in the log.
        // dives is DESC-sorted, so the last index seen for each diverName is the oldest dive.
        var firstDiveIdx: [String: Int] = [:]
        for (idx, dive) in dives.enumerated() {
            firstDiveIdx[dive.diverName] = idx
        }
        for idx in firstDiveIdx.values {
            cachedSummaries[idx].surfaceInterval = "0h 00m"
        }

        diveByID = Dictionary(dives.map { ($0.id, $0) }, uniquingKeysWith: { f, _ in f })

        // List update happens after summaries are built so rebuildFilteredDives can derive
        // cachedFilteredSummaries correctly. UI is still responsive on the same runloop turn.
        rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver)

        // Phase 3 — Heavy aggregation (O(n) set building + hashing) runs on a utility
        // thread so the MainActor is free during the suspension. Fish and marine-life
        // caches are only overwritten when the sweep was performed — when skipped they
        // remain current from the last membership-change sweep or from the incremental
        // refreshBadgeSets(for:) path.
        aggregationTask?.cancel()
        aggregationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let summarySnapshot = self.cachedSummaries
            let result = await Task.detached(priority: .utility) {
                DiveStore.computeDiveAggregation(from: summarySnapshot)
            }.value
            guard !Task.isCancelled else { return }
            self.cachedWidgetFingerprint = result.widgetFingerprint
            if membershipChanged {
                self.cachedDivesWithFish = result.divesWithFish
                self.cachedAvailableMarineLife = result.availableMarineLife
            }
            self.cachedAvailableYears = result.availableYears
            self.cachedAvailableGasTypes = result.availableGasTypes
            self.cachedAvailableCountries = result.availableCountries
            self.cachedAvailableDiveTypes = result.availableDiveTypes
            self.cachedAvailableTags = result.availableTags
        }
    }

    // Recomputes only the filter-sheet option lists. Called both from
    // rebuildDerivedDiveState() and lazily when the filter sheet is about to open,
    // so that in-place edits (marine life, country, tags) are reflected immediately.
    func rebuildFilterOptions() {
        var yearSet       = Set<Int>()
        var gasTypeSet    = Set<String>()
        var countrySet    = Set<String>()
        var diveTypeSet   = Set<String>()
        var tagSet        = Set<String>()
        var marineLifeSet = Set<String>()
        for summary in cachedSummaries {
            yearSet.insert(summary.year)
            if !summary.gasType.isEmpty { gasTypeSet.insert(summary.gasType) }
            if let c = summary.siteCountry, !c.isEmpty { countrySet.insert(c) }
            summary.diveTypes.forEach     { diveTypeSet.insert($0) }
            summary.tags.forEach          { tagSet.insert($0) }
            summary.seenFishNames.forEach { marineLifeSet.insert($0) }
        }
        cachedAvailableYears       = yearSet.sorted(by: >)
        cachedAvailableGasTypes    = gasTypeSet.sorted()
        cachedAvailableCountries   = countrySet.sorted()
        cachedAvailableDiveTypes   = diveTypeSet.sorted()
        cachedAvailableTags        = tagSet.sorted()
        cachedAvailableMarineLife  = marineLifeSet.sorted()
    }

    // Targeted badge refresh for a single dive after in-place photo or marine-life edits.
    // Only faults seenFish/photosData for the ONE changed dive, then refreshes filter options.
    @MainActor
    func refreshBadgeSets(for diveID: UUID, in dives: [Dive], showFilterSheet: Bool, selectedDiver: String) {
        guard let dive = dives.first(where: { $0.id == diveID }) else { return }
        let hasFish = !(dive.seenFish?.isEmpty ?? true)
        if hasFish { cachedDivesWithFish.insert(diveID) } else { cachedDivesWithFish.remove(diveID) }
        let hasPhotos = !(dive.photosData?.isEmpty ?? true)
        if hasPhotos { cachedDivesWithPhotos.insert(diveID) } else { cachedDivesWithPhotos.remove(diveID) }

        // Patch all summary caches BEFORE any rebuild so rebuildFilteredDives reads current data.
        // Also patches cachedFilteredSummaries/cachedGroupedSummaries directly so fish/photo badge
        // icons update immediately even when no marine-life filter triggers a full re-filter.
        let fish = dive.seenFish ?? []
        let names = fish.compactMap { sight -> String? in
            let n = sight.name.trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? nil : n
        }
        fishNamesByID[diveID] = names
        if let idx = cachedSummaries.firstIndex(where: { $0.id == diveID }) {
            cachedSummaries[idx].hasFish = hasFish
            cachedSummaries[idx].hasPhotos = hasPhotos
            cachedSummaries[idx].seenFishNames = names
        }
        if let idx = cachedFilteredSummaries.firstIndex(where: { $0.id == diveID }) {
            cachedFilteredSummaries[idx].hasFish = hasFish
            cachedFilteredSummaries[idx].hasPhotos = hasPhotos
            cachedFilteredSummaries[idx].seenFishNames = names
        }
        for i in cachedGroupedSummaries.indices {
            if let j = cachedGroupedSummaries[i].value.firstIndex(where: { $0.id == diveID }) {
                cachedGroupedSummaries[i].value[j].hasFish = hasFish
                cachedGroupedSummaries[i].value[j].hasPhotos = hasPhotos
                cachedGroupedSummaries[i].value[j].seenFishNames = names
            }
        }

        if showFilterSheet { rebuildFilterOptions() }
        // Re-filter immediately when a marine-life filter is active so that adding/removing
        // the filtered species causes the dive to appear/disappear from the list right away.
        if !filterMarineLife.isEmpty { rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
    }

    func rebuildFilteredDives(dives: [Dive], selectedDiver: String) {
        // Keep cachedSelectedDiver in sync on every call path — not just when routed through
        // rebuildDerivedDiveState. Direct calls from onChange(of: selectedDiver) / sort /
        // filter handlers would otherwise leave it stale, causing commit(.list) to rebuild
        // with the wrong diver scope.
        cachedSelectedDiver = selectedDiver
        // Does NOT rebuild diveIndexLookup (positional dive numbers). That is intentional:
        // only timestamp edits reorder the @Query array, and those always commit(_:affects: .list)
        // → scheduleRebuild(force:) → rebuildDerivedDiveState(), which rebuilds the lookup.
        // Fields committed with .rowFields (site, conditions, gas) cannot change @Query order.
        //
        // Fast path: when nothing is filtered and using the default date-desc sort, the @Query
        // result is already the correct full list in the right order — skip computeFilteredAndSortedDives().
        let source: [Dive]
        if searchText.isEmpty && activeFilterCount == 0 && selectedDiver.isEmpty && sortOrder == .dateDesc {
            source = dives
        } else {
            source = computeFilteredAndSortedDives(dives: dives, selectedDiver: selectedDiver)
        }
        let diverSet = Set(source.map { $0.diverName.trimmingCharacters(in: .whitespaces) })
        let showGrouped = selectedDiver.isEmpty && diverSet.count > 1
        cachedFilteredDives = source
        cachedShowGrouped = showGrouped
        cachedGroupedDives = showGrouped ? groupedDives(from: source) : []
        hasCacheBuilt = true

        // Derive summary caches from the live-Dive caches (O(n) map, no extra faults)
        let summaryByID = Dictionary(cachedSummaries.map { ($0.id, $0) }, uniquingKeysWith: { f, _ in f })
        cachedFilteredSummaries = cachedFilteredDives.compactMap { summaryByID[$0.id] }
        cachedGroupedSummaries = cachedGroupedDives.map { group in
            (key: group.key, value: group.value.compactMap { summaryByID[$0.id] })
        }
    }

    func updateWidgetDiveData(dives: [Dive]) {
        guard !dives.isEmpty else { return }
        struct DiveSnapshot {
            let diverName: String
            let duration: Int
            let maxDepth: Double
            let importDistanceUnit: String
            let timestamp: TimeInterval
        }
        // Capture value types on the main thread; computation runs on a background task.
        let snapshot = dives.map {
            DiveSnapshot(diverName: $0.diverName, duration: $0.duration,
                         maxDepth: $0.maxDepth, importDistanceUnit: $0.importDistanceUnit,
                         timestamp: $0.timestamp.timeIntervalSince1970)
        }
        let suiteName = widgetAppGroupSuite
        let prefs = UserPreferences.shared
        let depthUnitStr = prefs.depthUnit == .feet ? "feet" : "meters"
        let feetToMeters = 1.0 / DepthUnit.metersToFeetFactor

        // Write picker-critical keys synchronously so WidgetKit's suggestedEntities()
        // always sees the current diver list when the user opens the widget edit UI.
        let shared = UserDefaults(suiteName: suiteName)
        shared?.set(snapshot.count, forKey: "totalDiveCount")

        var countByDiver: [String: Int] = [:]
        for dive in snapshot {
            let name = dive.diverName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "__all__" else { continue }
            countByDiver[name, default: 0] += 1
        }
        let diverNames = countByDiver.keys.sorted()
        if let countData = try? JSONEncoder().encode(countByDiver) {
            shared?.set(countData, forKey: "diveCountByDiver")
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "DiveCountWidget")

        // Heavy stats aggregation runs in the background; DiverStatsWidget reloads after.
        Task.detached(priority: .utility) {
            let shared = UserDefaults(suiteName: suiteName)

            var totalMinutes: Int = 0
            var maxDepthMeters: Double = 0
            var longestDiveMinutes: Int = 0
            var mostRecent: TimeInterval = 0

            var totalMinutesByDiver: [String: Int] = [:]
            var maxDepthByDiver: [String: Double] = [:]
            var longestDiveByDiver: [String: Int] = [:]
            var mostRecentByDiver: [String: Double] = [:]

            for dive in snapshot {
                totalMinutes += dive.duration
                let factor = dive.importDistanceUnit == "feet" ? feetToMeters : 1.0
                let depthM = dive.maxDepth * factor
                if depthM > maxDepthMeters { maxDepthMeters = depthM }
                if dive.duration > longestDiveMinutes { longestDiveMinutes = dive.duration }
                if dive.timestamp > mostRecent { mostRecent = dive.timestamp }

                let name = dive.diverName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name != "__all__" else { continue }
                totalMinutesByDiver[name, default: 0] += dive.duration
                if depthM > (maxDepthByDiver[name] ?? 0) { maxDepthByDiver[name] = depthM }
                if dive.duration > (longestDiveByDiver[name] ?? 0) { longestDiveByDiver[name] = dive.duration }
                if dive.timestamp > (mostRecentByDiver[name] ?? 0) { mostRecentByDiver[name] = dive.timestamp }
            }

            shared?.set(totalMinutes, forKey: "totalMinutesUnderwater")
            shared?.set(maxDepthMeters, forKey: "maxDepthMeters")
            shared?.set(longestDiveMinutes, forKey: "longestDiveMinutes")
            shared?.set(depthUnitStr, forKey: "depthUnit")
            if mostRecent > 0 {
                shared?.set(mostRecent, forKey: "mostRecentDiveDate")
            } else {
                shared?.removeObject(forKey: "mostRecentDiveDate")
            }

            if let data = try? JSONEncoder().encode(totalMinutesByDiver) {
                shared?.set(data, forKey: "totalMinutesByDiver")
            }
            if let data = try? JSONEncoder().encode(maxDepthByDiver) {
                shared?.set(data, forKey: "maxDepthMetersByDiver")
            }
            if let data = try? JSONEncoder().encode(longestDiveByDiver) {
                shared?.set(data, forKey: "longestDiveMinutesByDiver")
            }
            if let data = try? JSONEncoder().encode(mostRecentByDiver) {
                shared?.set(data, forKey: "mostRecentDiveDateByDiver")
            }
            // Write diverNames here, after all per-diver stat dicts, so the widget
            // picker never shows a diver whose stats haven't been written yet.
            if let namesData = try? JSONEncoder().encode(diverNames) {
                shared?.set(namesData, forKey: "diverNames")
            }
            WidgetCenter.shared.reloadTimelines(ofKind: "DiverStatsWidget")
        }
    }

    // MARK: - Private Helpers

    private func computeFilteredAndSortedDives(dives: [Dive], selectedDiver: String) -> [Dive] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = DiverFilter.apply(selectedDiver, to: dives).filter { dive in
            // Text search
            if !query.isEmpty {
                let tagWords = dive.tags?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
                let diveTypesWords = dive.diveTypes?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
                let matches = dive.siteName.lowercased().contains(query)
                    || dive.location.lowercased().contains(query)
                    || dive.buddies.lowercased().contains(query)
                    || dive.diverName.lowercased().contains(query)
                    || (dive.siteCountry?.lowercased().contains(query) ?? false)
                    || diveTypesWords.contains(where: { $0.contains(query) })
                    || tagWords.contains(where: { $0.contains(query) })
                    || (dive.diveNumber.map { String($0) }?.contains(query) ?? false)
                if !matches { return false }
            }
            // Year filter
            if let year = filterYear {
                let diveYear = Calendar.current.component(.year, from: dive.timestamp)
                if filterYearNegate {
                    if diveYear == year { return false }
                } else {
                    if diveYear != year { return false }
                }
            }
            // Gas filter
            if let gas = filterGasType {
                if gas.isEmpty {
                    if !dive.gasType.isEmpty { return false }
                } else if filterGasTypeNegate {
                    if dive.gasType == gas { return false }
                } else {
                    if dive.gasType != gas { return false }
                }
            }
            // Depth range filter — compare in display units
            if filterMinDepth > 0 || filterMaxDepth > 0 {
                let depth = dive.displayMaxDepth
                if filterMinDepth > 0, filterMaxDepth > 0 {
                    let lo = Swift.min(filterMinDepth, filterMaxDepth)
                    let hi = Swift.max(filterMinDepth, filterMaxDepth)
                    if depth < lo || depth > hi { return false }
                } else if filterMinDepth > 0 {
                    if depth < filterMinDepth { return false }
                } else if filterMaxDepth > 0 {
                    if depth > filterMaxDepth { return false }
                }
            }
            // Minimum rating filter
            if filterMinRating > 0, dive.rating < filterMinRating { return false }
            // Country filter
            if let country = filterCountry {
                if country.isEmpty {
                    guard dive.siteCountry == nil || dive.siteCountry!.isEmpty else { return false }
                } else if filterCountryNegate {
                    if let diveCountry = dive.siteCountry, diveCountry == country { return false }
                } else {
                    guard let diveCountry = dive.siteCountry, diveCountry == country else { return false }
                }
            }
            // Dive type filter
            if let diveType = filterDiveType {
                if diveType.isEmpty {
                    let trimmed = dive.diveTypes?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !trimmed.isEmpty { return false }
                } else {
                    let allTypes = dive.diveTypes?
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                    if filterDiveTypeNegate {
                        if allTypes.contains(diveType) { return false }
                    } else {
                        if !allTypes.contains(diveType) { return false }
                    }
                }
            }
            // Tag filter
            if let tag = filterTag {
                if tag.isEmpty {
                    let trimmed = dive.tags?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !trimmed.isEmpty { return false }
                } else {
                    let diveTags = dive.tags?
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                    if !diveTags.contains(tag) { return false }
                }
            }
            // Marine life filter
            if !diveMatchesMarineLifeFilter(dive, species: filterMarineLife, mode: filterMarineLifeMode) { return false }
            return true
        }

        switch sortOrder {
        case .dateDesc:     break // @Query already delivers dives sorted by timestamp descending
        case .dateAsc:      result.sort { $0.timestamp < $1.timestamp }
        case .depthDesc:    result.sort { $0.displayMaxDepth > $1.displayMaxDepth }
        case .durationDesc: result.sort { $0.duration > $1.duration }
        case .diveNumberDesc: result.sort { ($0.diveNumber ?? 0) > ($1.diveNumber ?? 0) }
        case .diveNumberAsc:
            result.sort {
                switch ($0.diveNumber, $1.diveNumber) {
                case let (a?, b?): return a < b
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return false
                }
            }
        }
        return result
    }

    private func groupedDives(from sortedDives: [Dive]) -> [(key: String, value: [Dive])] {
        var order: [String] = []
        var dict: [String: [Dive]] = [:]
        for dive in sortedDives {
            let key = dive.diverName.trimmingCharacters(in: .whitespaces)
            if dict[key] == nil {
                order.append(key)
                dict[key] = []
            }
            dict[key]!.append(dive)
        }
        return order.map { (key: $0, value: dict[$0]!) }
    }

    // MARK: - Aggregation

    private struct DiveAggregationResult: Sendable {
        let widgetFingerprint: Int
        let divesWithFish: Set<UUID>
        let availableYears: [Int]
        let availableGasTypes: [String]
        let availableCountries: [String]
        let availableDiveTypes: [String]
        let availableTags: [String]
        let availableMarineLife: [String]
    }

    // nonisolated: escapes @MainActor isolation so Task.detached can call this on a
    // background thread without a hop back to the main actor.
    private nonisolated static func computeDiveAggregation(
        from snapshot: [DiveSummary]
    ) -> DiveAggregationResult {
        var hasher = Hasher()
        var withFish = Set<UUID>()
        var yearSet = Set<Int>()
        var gasTypeSet = Set<String>()
        var countrySet = Set<String>()
        var diveTypeSet = Set<String>()
        var tagSet = Set<String>()
        var marineLifeSet = Set<String>()

        for dive in snapshot {
            hasher.combine(dive.diverName)
            hasher.combine(dive.maxDepth.bitPattern)
            hasher.combine(dive.duration)
            hasher.combine(dive.importDistanceUnit)
            hasher.combine(dive.timestamp.timeIntervalSince1970.bitPattern)

            if dive.hasFish { withFish.insert(dive.id) }
            for name in dive.seenFishNames { marineLifeSet.insert(name) }

            yearSet.insert(dive.year)
            if !dive.gasType.isEmpty { gasTypeSet.insert(dive.gasType) }
            if let country = dive.siteCountry, !country.isEmpty { countrySet.insert(country) }
            dive.diveTypes.forEach { diveTypeSet.insert($0) }
            dive.tags.forEach { tagSet.insert($0) }
        }

        return DiveAggregationResult(
            widgetFingerprint: hasher.finalize(),
            divesWithFish: withFish,
            availableYears: yearSet.sorted(by: >),
            availableGasTypes: gasTypeSet.sorted(),
            availableCountries: countrySet.sorted(),
            availableDiveTypes: diveTypeSet.sorted(),
            availableTags: tagSet.sorted(),
            availableMarineLife: marineLifeSet.sorted()
        )
    }
}
