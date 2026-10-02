import SwiftUI
import SwiftData
import WidgetKit
import OSLog

// MARK: - Dive Sorting

/// The field the dive list is sorted by. Direction is a separate axis
/// (`DiveSortDirection`) so every field supports both orders — see issue #77.
///
/// Warning: these raw values are persisted `UserDefaults` identifiers (see
/// `DiveSortOrder.persisted`), not display strings — never rename one, or every
/// existing user's saved sort order silently resets to the default on next launch.
enum DiveSortField: String, CaseIterable, Identifiable {
    case date       = "date"
    case depth      = "depth"
    case duration   = "duration"
    case diveNumber = "diveNumber"

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .date:       return "Date"
        case .depth:      return "Depth"
        case .duration:   return "Duration"
        case .diveNumber: return "Dive #"
        }
    }

    /// The direction a field starts in when it is newly selected. Descending for every
    /// field, which reproduces the pre-toggle defaults exactly: newest, deepest,
    /// longest and highest-numbered first.
    var defaultDirection: DiveSortDirection { .descending }
}

/// Warning: these raw values are persisted `UserDefaults` identifiers (see
/// `DiveSortOrder.persisted`), not display strings — never rename one, or every
/// existing user's saved sort order silently resets to the default on next launch.
enum DiveSortDirection: String, CaseIterable {
    case ascending  = "Asc"
    case descending = "Desc"

    mutating func toggle() {
        self = (self == .ascending) ? .descending : .ascending
    }
}

/// A sort field paired with a direction.
///
/// Deliberately a struct rather than one enum case per field/direction combination:
/// adding a field does not double the case count, the filter sheet can render one
/// toggleable row per field, and reversing is `direction.toggle()` rather than an
/// 8-entry mapping table. It must stay a *struct* — as a class, an in-place
/// `direction` mutation would not reassign `DiveStore.sortOrder` and `@Observable`
/// would never notify `ContentView`'s `onChange(of: store.sortOrder)`. Never
/// hand-write `==` — the synthesized memberwise version comparing both `field` and
/// `direction` is what keeps the date-descending fast path (below) from firing for
/// any other order.
struct DiveSortOrder: Equatable, Hashable {
    var field: DiveSortField
    var direction: DiveSortDirection

    // Named to match the previous enum's cases. In practice only `.dateDesc` has
    // an existing call site (`= .dateDesc`, `== .dateDesc`, `.constant(.dateDesc)`)
    // — the rest are kept as convenience constants for the other seven
    // field/direction combinations, e.g. for future direct construction or tests.
    static let dateDesc       = DiveSortOrder(field: .date,       direction: .descending)
    static let dateAsc        = DiveSortOrder(field: .date,       direction: .ascending)
    static let depthDesc      = DiveSortOrder(field: .depth,      direction: .descending)
    static let depthAsc       = DiveSortOrder(field: .depth,      direction: .ascending)
    static let durationDesc   = DiveSortOrder(field: .duration,   direction: .descending)
    static let durationAsc    = DiveSortOrder(field: .duration,   direction: .ascending)
    static let diveNumberDesc = DiveSortOrder(field: .diveNumber, direction: .descending)
    static let diveNumberAsc  = DiveSortOrder(field: .diveNumber, direction: .ascending)
}

// MARK: - Dive Sort Persistence

extension DiveSortOrder {
    // The `UserDefaults` keys the dive list's sort field and direction are persisted under.
    private static let fieldDefaultsKey     = "diveListSortField"
    private static let directionDefaultsKey = "diveListSortDirection"

    /// Loads the persisted sort order, falling back to the date-descending default when
    /// no value has ever been saved (fresh install) or a saved value fails to decode.
    static var persisted: DiveSortOrder {
        let defaults = UserDefaults.standard
        // The direction is only meaningful paired with the field it was saved alongside.
        // If the field is missing or fails to decode, ignore any leftover direction and
        // fall back to the date-descending default as a unit.
        guard let field = DiveSortField(rawValue: defaults.string(forKey: fieldDefaultsKey) ?? "") else {
            return .dateDesc
        }
        let direction = DiveSortDirection(rawValue: defaults.string(forKey: directionDefaultsKey) ?? "") ?? field.defaultDirection
        return DiveSortOrder(field: field, direction: direction)
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(field.rawValue, forKey: Self.fieldDefaultsKey)
        defaults.set(direction.rawValue, forKey: Self.directionDefaultsKey)
    }

    /// Clears the persisted sort order so the next `persisted` read falls back to
    /// `.dateDesc`. Used by `UserPreferences.resetToDefaults()`, which has no handle
    /// to the live `DiveStore` and so cannot assign `sortOrder` directly.
    static func resetPersisted() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: fieldDefaultsKey)
        defaults.removeObject(forKey: directionDefaultsKey)
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
    var sortOrder: DiveSortOrder = .persisted {
        didSet { sortOrder.persist() }
    }

    // MARK: - Derived / Cached State
    private(set) var dives: [Dive] = []
    private(set) var diveIndexLookup: [UUID: Int] = [:]
    private(set) var cachedFilteredDives: [Dive] = []
    private(set) var cachedShowGrouped: Bool = false
    private(set) var cachedGroupedDives: [(key: String, value: [Dive])] = []
    private(set) var cachedUniqueDivers: [String] = []
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
    private var cachedGear: [Gear] = []
    private var cachedCertifications: [Certification] = []
    // cachedUniqueDivers has two independent feeders (ContentView for dives,
    // DiverSourcesFeeder for gear/certifications/insurance) whose first calls can arrive in
    // either order at launch. Until both halves have arrived once, a published list would be
    // incomplete but non-empty — enough for diverFilterReset to clear a persisted diver
    // selection that exists only in the missing half. See recomputeUniqueDivers().
    private var hasReceivedDives = false
    private var hasReceivedDiverSources = false
    private var cachedMarineSights: [MarineSight] = []
    private var cachedSelectedDiver: String = ""
    /// The trimmed searchText value actually applied to cachedFilteredSummaries as of the
    /// last rebuildFilteredDives call — lags live searchText by up to scheduleSearchRebuild's
    /// 150ms debounce. Sibling of cachedSelectedDiver above: both are "last value actually
    /// applied," synced together in rebuildFilteredDives. Views deciding what empty-state to
    /// show must check this, not searchText directly, or they can render a state describing
    /// search results that haven't been computed yet (e.g. a diver-specific empty state while
    /// a stale search is still applied).
    private(set) var appliedSearchText: String = ""

    // MARK: - Summary Cache
    private(set) var cachedSummaries: [DiveSummary] = []
    private(set) var cachedFilteredSummaries: [DiveSummary] = []
    private(set) var cachedGroupedSummaries: [(key: String, value: [DiveSummary])] = []
    private(set) var diveByID: [UUID: Dive] = [:]
    private var fishNamesByID: [UUID: [String]] = [:]
    /// Maps persistent-history identifiers back to dive UUIDs (rebuilt with diveByID).
    @ObservationIgnored private var diveIDByPID: [PersistentIdentifier: UUID] = [:]
    /// The chronologically oldest dive of each diver, whose surface interval is shown as
    /// "0h 00m". Only changes on timestamp/diver/membership edits, which all rebuild it.
    @ObservationIgnored private var oldestDiveIDs: Set<UUID> = []
    /// The latest @Query delivery (see rebuildFromLatestQueryDelivery).
    @ObservationIgnored private var latestQueryDives: [Dive]?
    @ObservationIgnored private var latestQuerySights: [MarineSight]?

    // MARK: - Remote Change State
    // See applyRemoteHistory(container:). Kept here, not in RemoteChangeFeeder, so the
    // position survives the feeder being recreated (e.g. a macOS window closed and reopened).
    @ObservationIgnored private var remoteHistoryToken: DefaultHistoryToken?
    /// Starting point of the first history fetch. Set at launch, before the first @Query
    /// delivery, so no transaction between launch and the first rebuild is missed.
    @ObservationIgnored private var remoteHistoryBaseline = Date()
    @ObservationIgnored private var isApplyingRemoteHistory = false
    @ObservationIgnored private var remoteHistoryRerunRequested = false
    /// Dives deleted on another device that are still in `dives` because the @Query has not
    /// re-delivered yet. Until they are gone, no remote batch touches the caches: reading a
    /// deleted SwiftData object is unsafe, and the @Query's own full rebuild covers the batch.
    @ObservationIgnored private var pendingRemoteDeletedPIDs: Set<PersistentIdentifier> = []
    /// While a backlog arrives in several pages, the pages are only noted; the last one applies
    /// everything at once (one full rebuild when any listed dive changed, plus badge refreshes).
    @ObservationIgnored private var notedPages = NotedRemotePages()
    /// After a merge-wait timeout the same batch is re-read once (see applyRemoteHistoryBatch).
    @ObservationIgnored private var remoteRetriedAfterTimeout = false
    /// A batch was deferred because a listed dive is gone from the store. Its position is kept;
    /// the next full rebuild (normally the @Query delivering the deletion) re-runs it.
    @ObservationIgnored private var remoteDeferralPending = false
    /// The deletions that caused the last deferral; an unchanged set ends a re-run early.
    @ObservationIgnored private var deferredPendingPIDs: Set<PersistentIdentifier> = []
    /// Remembered from the feeder so a rebuild can re-run a deferred batch.
    @ObservationIgnored private var remoteHistoryContainer: ModelContainer?
    /// Bumped whenever the fish/photo badge caches change; see scheduleAggregation.
    @ObservationIgnored private var badgeCacheGeneration = 0

    // MARK: - Background Tasks
    private var searchDebounceTask: Task<Void, Never>?
    private var aggregationTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    /// See scheduleAggregation(updateFishCaches:).
    @ObservationIgnored private var aggregationIncludesFishCaches = false

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

    // Resets only the filter criteria — sort order is a durable, persisted preference
    // and is deliberately left untouched here.
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
            // immediately. A debounced rebuild would be cancelled within its 50ms window by
            // the @Query re-delivery this edit triggers, and that re-delivery's own scheduled
            // rebuild then short-circuits on matching IDs and never runs, leaving the list in
            // the wrong order.
            rebuildFromLatestQueryDelivery()
        case .rowBadges:
            refreshBadgeSets(for: dive.id, in: dives, showFilterSheet: showFilterSheet, selectedDiver: cachedSelectedDiver)
        case .rowFields:
            // Patch the one affected DiveSummary, preserving badge state.
            patchSummaries(for: [dive.id])
            // Full re-filter only when an active filter could change this dive's membership.
            if filtersAffectMembership {
                rebuildFilteredDives(dives: dives, selectedDiver: cachedSelectedDiver)
            } else {
                // Fast path: re-derive filtered summary caches from the patched cachedSummaries
                // without an O(n) filter pass over all dives.
                rederiveFilteredSummaries()
            }
        case .nothing:
            break
        }
    }

    func commitListRebuild() {
        // Same synchronous bypass as commit(.list) — avoids the debounce-cancellation race
        // where a @Query re-delivery kills the pending debounced rebuild before it runs.
        rebuildFromLatestQueryDelivery()
    }

    /// Synchronous full rebuild for commit(.list) and commitListRebuild(). It cancels any
    /// debounced @Query rebuild, so it reads the latest @Query delivery (recorded by
    /// scheduleRebuild and rebuildDerivedDiveState) rather than `dives`: a delivery still in
    /// the 50 ms debounce — e.g. a dive added by the same iCloud import — would otherwise be
    /// dropped until the next membership change, because saving never re-delivers the @Query.
    private func rebuildFromLatestQueryDelivery() {
        rebuildTask?.cancel()
        rebuildTask = nil
        let sortedDives = (latestQueryDives ?? dives).sorted { $0.timestamp > $1.timestamp }
        rebuildDerivedDiveState(dives: sortedDives,
                                allMarineSights: latestQuerySights ?? cachedMarineSights,
                                selectedDiver: cachedSelectedDiver)
    }

    // Patches surfaceInterval in all three summary caches without a full rebuild.
    // Called on the MainActor from recalcSequencesInBackground after the
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
        rederiveFilteredSummaries()
    }

    // Patches diveNumber in all three summary caches without a full rebuild.
    // Mirrors commitSurfaceIntervals — called on the MainActor from
    // recalcSequencesInBackground after the background context's renumber
    // completes, delivering computed dive numbers directly rather than waiting
    // for @Query to re-deliver.
    func commitDiveNumbers(_ updates: [UUID: Int]) {
        for idx in cachedSummaries.indices {
            if let n = updates[cachedSummaries[idx].id] {
                cachedSummaries[idx].diveNumber = n
            }
        }
        rederiveFilteredSummaries()
    }

    // Spawns a background task that recalculates surface intervals AND renumbers
    // dives for the diver group(s) affected by an edit, then patches cachedSummaries
    // via commitSurfaceIntervals and commitDiveNumbers on the MainActor. Recalculates
    // newDiverName's group, and additionally originalDiverName's group when the two
    // differ (a diver move). For a timestamp-only edit, pass the same name for both
    // parameters to recalc that single diver's sequence. Must be called after
    // modelContext.save() so the background context reads the already-persisted state.
    func recalcSequencesInBackground(
        container: ModelContainer,
        newDiverName: String,
        originalDiverName: String
    ) {
        Task.detached(priority: .utility) { [weak self] in
            let bgContext = ModelContext(container)
            // Tags this context's saves in persistent history as the app's own (not an iCloud import).
            bgContext.author = "BlueDive.background"
            var siUpdates = Dive.recalculateSurfaceIntervals(in: bgContext, diverName: newDiverName)
            var numberUpdates = Dive.renumberDives(in: bgContext, diverName: newDiverName)
            if newDiverName != originalDiverName {
                let extraSI = Dive.recalculateSurfaceIntervals(in: bgContext, diverName: originalDiverName)
                siUpdates.merge(extraSI) { _, new in new }
                let extraNumbers = Dive.renumberDives(in: bgContext, diverName: originalDiverName)
                numberUpdates.merge(extraNumbers) { _, new in new }
            }
            let finalSI = siUpdates
            let finalNumbers = numberUpdates
            await MainActor.run { [weak self] in
                self?.commitSurfaceIntervals(finalSI)
                self?.commitDiveNumbers(finalNumbers)
            }
        }
    }

    // MARK: - Pipeline

    // Coalesces rapid-fire triggers into a single rebuild after a 50ms quiet period.
    // Skips the rebuild if dive membership is unchanged — this suppresses spurious @Query
    // re-deliveries that fire when edit sheets open/close without modifying data. Field-level
    // dive edits (site, conditions, gas, etc.) go through commit(_:affects: .rowFields) instead
    // and never reach this debounce at all, so an unconditional membership check is always correct here.
    func scheduleRebuild(
        dives: [Dive],
        allMarineSights: [MarineSight],
        selectedDiver: String
    ) {
        // Recorded before the debounce, so a synchronous rebuild in the meantime still sees it.
        latestQueryDives = dives
        latestQuerySights = allMarineSights
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            let currentIDs = Set(dives.map { $0.id })
            guard currentIDs != self.lastPhotoSweepDiveIDs else { return }
            self.rebuildDerivedDiveState(dives: dives, allMarineSights: allMarineSights, selectedDiver: selectedDiver)
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
        allMarineSights: [MarineSight],
        selectedDiver: String
    ) {
        self.dives = dives
        self.hasReceivedDives = true
        self.cachedSelectedDiver = selectedDiver
        self.cachedMarineSights = allMarineSights
        // Also covers ContentView's first-mount rebuild, which does not go through scheduleRebuild.
        self.latestQueryDives = dives
        self.latestQuerySights = allMarineSights
        // Phase 1 — Fast synchronous work on MainActor. Must complete before returning
        // so callers see a consistent index and filtered list immediately.
        recomputeUniqueDivers()

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

        // The chronologically oldest dive per diver has no preceding dive, so its surface
        // interval is definitionally zero. Imported dives may carry a stale value from the
        // source file; makeSummary(for:) clears it so the badge is never shown for the first
        // dive in the log. dives is DESC-sorted, so the last index seen for each diverName is
        // the oldest dive.
        var firstDiveIdx: [String: Int] = [:]
        for (idx, dive) in dives.enumerated() {
            firstDiveIdx[dive.diverName] = idx
        }
        oldestDiveIDs = Set(firstDiveIdx.values.map { dives[$0].id })

        cachedSummaries = dives.map { makeSummary(for: $0) }

        diveByID = Dictionary(dives.map { ($0.id, $0) }, uniquingKeysWith: { f, _ in f })
        diveIDByPID = Dictionary(dives.map { ($0.persistentModelID, $0.id) }, uniquingKeysWith: { f, _ in f })

        // List update happens after summaries are built so rebuildFilteredDives can derive
        // cachedFilteredSummaries correctly. UI is still responsive on the same runloop turn.
        rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver)

        // Phase 3 — Heavy aggregation. Fish and marine-life caches are only overwritten when
        // the sweep was performed — when skipped they remain current from the last
        // membership-change sweep or from the incremental refreshBadgeSets(for:) path.
        scheduleAggregation(updateFishCaches: membershipChanged)

        // A remote batch deferred for a pending deletion re-runs after the rebuild that
        // (normally) delivers that deletion.
        if remoteDeferralPending, let container = remoteHistoryContainer {
            Task { await self.applyRemoteHistory(container: container) }
        }
    }

    /// Runs the O(n) aggregation (set building + hashing) on a utility thread so the
    /// MainActor is free during the suspension, then publishes the filter-option lists and
    /// the widget fingerprint. `updateFishCaches` also publishes the dives-with-fish set and
    /// the marine-life option list; pass it when the badge caches are current (the summaries'
    /// badges are copied from them).
    private func scheduleAggregation(updateFishCaches: Bool) {
        // A cancelled run's fish-cache request carries over to its replacement, so a later
        // call with `false` cannot drop it.
        aggregationIncludesFishCaches = aggregationIncludesFishCaches || updateFishCaches
        aggregationTask?.cancel()
        aggregationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let summarySnapshot = self.cachedSummaries
            let generation = self.badgeCacheGeneration
            let result = await Task.detached(priority: .utility) {
                DiveStore.computeDiveAggregation(from: summarySnapshot)
            }.value
            guard !Task.isCancelled else { return }
            let updateFishCaches = self.aggregationIncludesFishCaches
            self.aggregationIncludesFishCaches = false
            // The store writes the widget's App Group data itself whenever the fingerprint
            // changes, so remote edits reach the widget even while the Dives tab (ContentView)
            // is not shown. Built from the summary snapshot, never from `dives`: a dive deleted
            // on another device may have merged during the await above.
            if result.widgetFingerprint != self.cachedWidgetFingerprint {
                self.cachedWidgetFingerprint = result.widgetFingerprint
                self.updateWidgetDiveData(summaries: summarySnapshot)
            }
            if updateFishCaches {
                if generation == self.badgeCacheGeneration {
                    self.cachedDivesWithFish = result.divesWithFish
                    self.cachedAvailableMarineLife = result.availableMarineLife
                } else {
                    // A badge refresh ran during the compute; publishing this older snapshot
                    // would undo it. Aggregate again from the current summaries.
                    self.scheduleAggregation(updateFishCaches: true)
                    return
                }
            }
            self.cachedAvailableYears = result.availableYears
            self.cachedAvailableGasTypes = result.availableGasTypes
            self.cachedAvailableCountries = result.availableCountries
            self.cachedAvailableDiveTypes = result.availableDiveTypes
            self.cachedAvailableTags = result.availableTags
        }
    }

    // MARK: - Summary Helpers

    /// Builds one dive's summary. Badges come from `badgesFrom` when given (a field-only
    /// patch keeps the row's current badges), otherwise from the badge caches.
    private func makeSummary(for dive: Dive, badgesFrom existing: DiveSummary? = nil) -> DiveSummary {
        var s = DiveSummary(from: dive)
        if let existing {
            s.hasFish       = existing.hasFish
            s.hasPhotos     = existing.hasPhotos
            s.seenFishNames = existing.seenFishNames
        } else {
            s.hasFish       = cachedDivesWithFish.contains(dive.id)
            s.hasPhotos     = cachedDivesWithPhotos.contains(dive.id)
            s.seenFishNames = fishNamesByID[dive.id] ?? []
        }
        if oldestDiveIDs.contains(dive.id) { s.surfaceInterval = "0h 00m" }
        return s
    }

    /// Rebuilds the summaries of the given dives in a local copy and publishes it with a
    /// single assignment. `badgesFromCaches` dives take their badges from the badge caches
    /// (after a badge refresh); the others keep their current badges.
    private func patchSummaries(for ids: Set<UUID>, badgesFromCaches: Set<UUID> = []) {
        guard !ids.isEmpty else { return }
        var summaries = cachedSummaries
        for idx in summaries.indices where ids.contains(summaries[idx].id) {
            guard let dive = diveByID[summaries[idx].id] else { continue }
            summaries[idx] = badgesFromCaches.contains(dive.id)
                ? makeSummary(for: dive)
                : makeSummary(for: dive, badgesFrom: summaries[idx])
        }
        cachedSummaries = summaries
    }

    /// Re-derives the filtered and grouped summary caches from `cachedSummaries`, keeping the
    /// current filtered order. One assignment each: element-level mutations of
    /// cachedGroupedSummaries fire rapid @Observable notifications that make Section(isExpanded:)
    /// drop section headers in the .sidebar list on iPad/Mac.
    private func rederiveFilteredSummaries() {
        let summaryByID = Dictionary(cachedSummaries.map { ($0.id, $0) }, uniquingKeysWith: { f, _ in f })
        cachedFilteredSummaries = cachedFilteredDives.compactMap { summaryByID[$0.id] }
        cachedGroupedSummaries = cachedGroupedDives.map { group in
            (key: group.key, value: group.value.compactMap { summaryByID[$0.id] })
        }
    }

    /// True when an active search or filter could change which dives a field edit leaves in the list.
    private var filtersAffectMembership: Bool {
        !searchText.isEmpty
            || filterCountry  != nil || filterGasType  != nil
            || filterDiveType != nil || filterTag       != nil
            || filterMinDepth  > 0  || filterMaxDepth   > 0
            || filterMinRating > 0  || !filterMarineLife.isEmpty
    }

    // Diver-name sources — see updateDiverSources below.
    /// Refreshes ONLY the cached diver-name list from the non-Dive sources.
    ///
    /// Deliberately bypasses scheduleRebuild()/rebuildDerivedDiveState(): a gear,
    /// certification or insurance edit cannot change dive order, row fields or row
    /// badges, so routing it through the full pipeline would rebuild every
    /// DiveSummary (10 000+ dives) to refresh a name list. Called only by
    /// DiverSourcesFeeder (always mounted behind MainTabView's TabView). Every screen that
    /// shows a diver list — filter menus and Diver field suggestions alike — reads
    /// cachedUniqueDivers instead of querying gear/certifications/insurance itself.
    func updateDiverSources(gear: [Gear], certifications: [Certification], insurances: [DivingInsurance]) {
        cachedGear = gear
        cachedCertifications = certifications
        cachedInsurances = insurances
        hasReceivedDiverSources = true
        recomputeUniqueDivers()
    }

    private func recomputeUniqueDivers() {
        // Publish only a complete list: see hasReceivedDives / hasReceivedDiverSources.
        guard hasReceivedDives && hasReceivedDiverSources else { return }
        let names = DiverFilter.uniqueDivers(
            in: dives, gear: cachedGear,
            certifications: cachedCertifications, insurances: cachedInsurances
        )
        // @Observable fires on every assignment regardless of equality. The @Query re-delivery
        // that triggered this call already invalidated ContentView's body; this guard instead
        // stops that no-op from propagating further downstream, to diverFilterReset's
        // task(id: uniqueDivers) and the onChange(of: store.cachedUniqueDivers) handler that
        // intersects collapsedDiverSections.
        if names != cachedUniqueDivers { cachedUniqueDivers = names }
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
            summary.gasNames.forEach   { gasTypeSet.insert($0) }
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
        badgeCacheGeneration &+= 1
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
        // with the wrong diver scope. appliedSearchText is synced here for the same reason.
        cachedSelectedDiver = selectedDiver
        appliedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Does NOT rebuild diveIndexLookup (positional dive numbers). That is intentional:
        // only timestamp edits reorder the @Query array, and those always commit(_:affects: .list)
        // → rebuildDerivedDiveState(), which rebuilds the lookup.
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
        rederiveFilteredSummaries()
    }

    /// The per-dive values the widget statistics are computed from.
    private struct WidgetDiveSnapshot: Sendable {
        let diverName: String
        let duration: Int
        let maxDepth: Double
        let importDistanceUnit: String
        let timestamp: TimeInterval
    }

    /// Writes the widget's App Group data from live dives (ContentView, which holds the
    /// current @Query result).
    func updateWidgetDiveData(dives: [Dive]) {
        // Capture value types on the main thread; computation runs on a background task.
        writeWidgetData(dives.map {
            WidgetDiveSnapshot(diverName: $0.diverName, duration: $0.duration,
                               maxDepth: $0.maxDepth, importDistanceUnit: $0.importDistanceUnit,
                               timestamp: $0.timestamp.timeIntervalSince1970)
        })
    }

    /// Writes the widget's App Group data from summaries (value types, safe to read after an
    /// await). Same values as the Dive-based entry point: summaries carry the raw stored
    /// depth, unit, duration and timestamp, and the diver name trimmed (trimmed again below).
    private func updateWidgetDiveData(summaries: [DiveSummary]) {
        writeWidgetData(summaries.map {
            WidgetDiveSnapshot(diverName: $0.diverName, duration: $0.duration,
                               maxDepth: $0.maxDepth, importDistanceUnit: $0.importDistanceUnit,
                               timestamp: $0.timestamp.timeIntervalSince1970)
        })
    }

    private func writeWidgetData(_ snapshot: [WidgetDiveSnapshot]) {
        guard !snapshot.isEmpty else { return }
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

    // MARK: - Remote Changes (iCloud)
    //
    // Edits another device makes to an existing dive arrive through CloudKit as persistent-
    // history transactions. They change no dive membership, so ContentView's @Query path never
    // rebuilds for them (SwiftData models compare by identity, and scheduleRebuild skips when
    // the dive IDs are unchanged). RemoteChangeFeeder calls applyRemoteHistory(container:)
    // after each burst of .NSPersistentStoreRemoteChange notifications; it reads the new
    // transactions, keeps only other devices' changes, and patches just the affected dives:
    //
    //   timestamp, diverName, current sort field      → one full rebuild (commitListRebuild)
    //   seenFish, photosData                          → badge refresh for those dives
    //   other fields shown in rows (DiveSummary)      → summary patch for those dives
    //   anything else (notes, averageDepth, profile…) → nothing
    //
    // Dive inserts and deletes are left to the @Query membership path. A fish added or removed
    // on another device always comes with a seenFish update on its dive; a fish renamed there
    // changes only its MarineSight row, so its parent dive's badges are refreshed explicitly.
    // Surface intervals and dive numbers arrive already calculated by the other device and are
    // never recalculated here (that would bounce writes between devices).

    /// This app's own contexts set `author` with this prefix ("BlueDive.main",
    /// "BlueDive.background"); their saves are already reflected through commit(_:affects:).
    private static let appHistoryAuthorPrefix = "BlueDive."
    /// Author of the read-only contexts used here (they never save; set for consistency).
    private nonisolated static let remoteHistoryAuthor = "BlueDive.remoteHistory"
    /// Transactions per history fetch. When more follow, the page is only noted and the next
    /// fetch continues right after it; the last page applies the whole backlog at once.
    private nonisolated static let remoteTransactionLimit = 500
    /// Above this many changed dives this device lists, one full rebuild is cheaper than
    /// patching (each patched dive costs one fetch on the MainActor).
    private static let remoteDiveUpdateLimit = 100
    /// Dives checked for the main-context merge before a full rebuild.
    private static let remoteMergeSampleSize = 20
    /// Most renamed fish resolved per batch (one fetch each, with yields, before the wait).
    private static let remoteRenamedSightLimit = 300
    /// Most dives whose fish/photo badges are refreshed per batch. That refresh faults seenFish
    /// and photosData synchronously after the final deletion check (no yield possible there).
    /// Above it their fish names stay as they are until the next change in dive membership.
    private static let remoteBadgeRefreshLimit = 100

    /// Other devices' changes in one history fetch, by persistent identifier.
    private struct RemoteHistoryBatch {
        var newestToken: DefaultHistoryToken?
        /// The fetch hit its limit: more transactions follow this batch.
        var hasMoreTransactions = false
        var listPIDs: Set<PersistentIdentifier> = []
        var rowPIDs: Set<PersistentIdentifier> = []
        var badgePIDs: Set<PersistentIdentifier> = []
        /// The badge dives whose photos changed (a subset of badgePIDs). Only these have their
        /// photo count compared, which loads every photo blob of the dive.
        var photoPIDs: Set<PersistentIdentifier> = []
        var deletedPIDs: Set<PersistentIdentifier> = []
        /// MarineSight rows whose name changed; resolved to their parent dives' badges.
        var renamedSightPIDs: Set<PersistentIdentifier> = []
        /// Dives inserted by this app's own saves (permanent identifiers), used to remap dives
        /// recorded under a temporary identifier before they were first saved.
        var localInsertedPIDs: Set<PersistentIdentifier> = []
        var updatedPIDs: Set<PersistentIdentifier> { listPIDs.union(rowPIDs).union(badgePIDs) }
        var isEmpty: Bool {
            updatedPIDs.isEmpty && deletedPIDs.isEmpty && renamedSightPIDs.isEmpty && localInsertedPIDs.isEmpty
        }
    }

    /// What earlier pages of a backlog carry over to the last page. Deliberately not their
    /// list/row sets: the last page applies a full rebuild instead, and carrying them would make
    /// dives look "newly listed" (see applyRemoteHistoryBatch).
    private struct NotedRemotePages {
        var fullRebuild = false
        var samplePIDs: Set<PersistentIdentifier> = []
        var badgePIDs: Set<PersistentIdentifier> = []
        var photoPIDs: Set<PersistentIdentifier> = []
        var renamedSightPIDs: Set<PersistentIdentifier> = []
        var deletedPIDs: Set<PersistentIdentifier> = []
        var localInsertedPIDs: Set<PersistentIdentifier> = []

        var isEmpty: Bool {
            !fullRebuild && samplePIDs.isEmpty && badgePIDs.isEmpty && photoPIDs.isEmpty
                && renamedSightPIDs.isEmpty && deletedPIDs.isEmpty && localInsertedPIDs.isEmpty
        }

        /// Notes one page; `listedUpdates` are its updates to dives this device lists.
        mutating func note(_ page: RemoteHistoryBatch, listedUpdates: Set<PersistentIdentifier>, sampleSize: Int) {
            if !listedUpdates.isEmpty { fullRebuild = true }
            samplePIDs.formUnion(listedUpdates.prefix(max(0, sampleSize - samplePIDs.count)))
            badgePIDs.formUnion(page.badgePIDs)
            photoPIDs.formUnion(page.photoPIDs)
            renamedSightPIDs.formUnion(page.renamedSightPIDs)
            deletedPIDs.formUnion(page.deletedPIDs)
            localInsertedPIDs.formUnion(page.localInsertedPIDs)
        }

        /// Adds the noted sets to the last page's batch (not the flag or the sample).
        func carry(into batch: inout RemoteHistoryBatch) {
            batch.badgePIDs.formUnion(badgePIDs)
            batch.photoPIDs.formUnion(photoPIDs)
            batch.renamedSightPIDs.formUnion(renamedSightPIDs)
            batch.deletedPIDs.formUnion(deletedPIDs)
            batch.localInsertedPIDs.formUnion(localInsertedPIDs)
        }
    }

    /// One changed dive as committed in the store, read through a fresh context.
    private struct RemoteDiveExpectation {
        let summary: DiveSummary
        let fishNames: [String]?
        let photoCount: Int?
    }

    /// Applies other devices' edits to existing dives. Called by RemoteChangeFeeder; runs are
    /// serialized, and a call made while one is running triggers one more run afterwards.
    func applyRemoteHistory(container: ModelContainer) async {
        remoteHistoryContainer = container
        guard !isApplyingRemoteHistory else {
            remoteHistoryRerunRequested = true
            return
        }
        isApplyingRemoteHistory = true
        defer { isApplyingRemoteHistory = false }
        repeat {
            remoteHistoryRerunRequested = false
            await applyRemoteHistoryBatch(container: container)
        } while remoteHistoryRerunRequested
    }

    private func applyRemoteHistoryBatch(container: ModelContainer) async {
        // Before the first rebuild there is nothing to patch; that rebuild reads everything.
        guard hasCacheBuilt else { return }

        // The history read decodes every change, so it runs off the MainActor.
        let token = remoteHistoryToken
        let baseline = remoteHistoryBaseline
        let fetched = await Task.detached(priority: .utility) {
            Result { try DiveStore.fetchHistoryTransactions(container: container, after: token, since: baseline) }
        }.value

        let transactions: [DefaultHistoryTransaction]
        switch fetched {
        case .success(let result):
            transactions = result
        case .failure(let error):
            // E.g. an expired token. Restart from now; changes in the gap are picked up by the
            // next full rebuild. No rebuild here: without the history this batch's deletions are
            // unknown, and rebuilding over a remotely deleted dive is unsafe.
            logRemoteHistory("history fetch failed (\(error.localizedDescription)); restarting from now")
            remoteHistoryToken = nil
            remoteHistoryBaseline = Date()
            return
        }

        var batch = classifyRemoteHistory(transactions)
        // nil when nothing new was fetched; noted pages or a deferral may still need applying
        // (e.g. a backlog that was an exact multiple of the page size).
        let newestToken = batch.newestToken

        if batch.hasMoreTransactions, let newestToken {
            // More pages follow (a long time offline or a first sync): don't touch the caches
            // yet. Note what this page needs and continue; the last page applies everything
            // with one full rebuild, so a backlog costs one rebuild rather than one per page.
            if !batch.localInsertedPIDs.isEmpty {
                // Remap first, so edits to dives this app just saved count as listed.
                await remapLocallyInsertedDives(batch.localInsertedPIDs.union(notedPages.localInsertedPIDs),
                                                in: makeRemoteHistoryContext(container))
            }
            let listedUpdates = batch.updatedPIDs.filter { diveIDByPID[$0] != nil }
            notedPages.note(batch, listedUpdates: listedUpdates, sampleSize: Self.remoteMergeSampleSize)
            advanceRemoteHistory(to: newestToken)
            remoteHistoryRerunRequested = true
            logRemoteHistory("page noted, more to fetch")
            return
        }

        // Last page: add what the earlier pages noted.
        notedPages.carry(into: &batch)
        let fullRebuildPending = notedPages.fullRebuild
        // A local insert needs remapping only while the map still holds a temporary identifier;
        // otherwise every local add-dive save would run the whole path for nothing.
        if diveIDByPID.keys.contains(where: { $0.storeIdentifier == nil }) {
            batch.localInsertedPIDs = batch.localInsertedPIDs.filter { diveIDByPID[$0] == nil }
        } else {
            batch.localInsertedPIDs = []
        }
        guard !batch.isEmpty || fullRebuildPending || remoteDeferralPending else {
            if let newestToken { advanceRemoteHistory(to: newestToken) }
            clearNotedRemotePages()
            return
        }

        // A deferred batch re-run before its deletions reached the list: nothing to do yet (a
        // deleted identifier cannot come back, so "still listed" means "unchanged"). The next
        // rebuild re-runs it.
        if remoteDeferralPending, !deferredPendingPIDs.isEmpty,
           deferredPendingPIDs.allSatisfy({ diveIDByPID[$0] != nil }) {
            logRemoteHistory("still deferred (\(deferredPendingPIDs.count) deletion(s) pending)")
            return
        }

        // One read-only context reads committed values straight from the store.
        let fresh = makeRemoteHistoryContext(container)

        // Dives this app inserted and has since saved may be recorded under their temporary
        // identifier (e.g. an import that saves at the end); map their permanent one first.
        await remapLocallyInsertedDives(batch.localInsertedPIDs, in: fresh)

        // A fish renamed on another device changes only its MarineSight row.
        if batch.renamedSightPIDs.count <= Self.remoteRenamedSightLimit {
            batch.badgePIDs.formUnion(await parentDivePIDs(ofSights: batch.renamedSightPIDs, in: fresh))
        } else {
            logRemoteHistory("\(batch.renamedSightPIDs.count) renamed fish: names refresh at the next membership change")
        }

        // Only dives this device lists can be patched; the others arrive through the @Query.
        let knownUpdated = batch.updatedPIDs.filter { diveIDByPID[$0] != nil }
        let fullRebuild = fullRebuildPending || knownUpdated.count > Self.remoteDiveUpdateLimit

        // The change is committed in the store before the main context merges it (~1 s later).
        // Read the committed values through the fresh context, then wait until the main context
        // shows them, so no dive is patched with its old values. Before a full rebuild a sample
        // (from every page of a backlog) is enough to know the merge has landed — plus every
        // dive whose badges are refreshed, since the rebuild keeps those badges as refreshed.
        let checked: Set<PersistentIdentifier>
        if fullRebuild {
            let knownBadge = batch.badgePIDs.intersection(knownUpdated)
            let sample = Set(notedPages.samplePIDs.union(knownUpdated)
                .filter { diveIDByPID[$0] != nil }
                .prefix(Self.remoteMergeSampleSize))
            checked = sample.union(knownBadge.count <= Self.remoteBadgeRefreshLimit ? knownBadge : [])
        } else {
            checked = knownUpdated
        }
        let committed = await freshExpectations(for: checked, badgePIDs: batch.badgePIDs,
                                                photoPIDs: batch.photoPIDs, in: fresh)
        let merged = await waitForMainContextMerge(of: committed.expectations,
                                                   deletedHints: batch.deletedPIDs.union(committed.missing),
                                                   in: fresh)
        // No await from here on: nothing can merge into the main context before the caches are
        // updated, so the full deletion check made by the last wait attempt still holds.

        guard pendingRemoteDeletedPIDs.isEmpty else {
            // A dive this device lists is gone from the store. Reading it would crash. Keep the
            // position and the noted pages: the next full rebuild — normally the @Query
            // delivering the deletion — re-runs this batch (see rebuildDerivedDiveState).
            logRemoteHistory("deferred (\(pendingRemoteDeletedPIDs.count) deletion(s) pending)")
            remoteDeferralPending = true
            deferredPendingPIDs = pendingRemoteDeletedPIDs
            return
        }
        // Cleared before any patch: the full rebuild below must not re-run this batch.
        remoteDeferralPending = false
        deferredPendingPIDs = []

        // Re-resolve after the waits, and only patch dives whose merge was checked.
        func ids(_ pids: Set<PersistentIdentifier>) -> Set<UUID> {
            Set(pids.intersection(knownUpdated).compactMap { diveIDByPID[$0] })
        }
        let listIDs  = ids(batch.listPIDs)
        let rowIDs   = ids(batch.rowPIDs)
        var badgeIDs = ids(batch.badgePIDs)
        let photoIDs = ids(batch.photoPIDs)
        let rebuilds = fullRebuild || !listIDs.isEmpty

        // A changed dive that joined the list during the wait (added and edited on the other
        // device) was not checked. When no full rebuild re-reads everything, keep the position and
        // run once more: it is then known and checked. Bounded, as it cannot be "new" twice.
        let newlyListed = batch.updatedPIDs.subtracting(knownUpdated).filter { diveIDByPID[$0] != nil }
        if !rebuilds && !newlyListed.isEmpty {
            remoteHistoryRerunRequested = true
            logRemoteHistory("\(newlyListed.count) dive(s) joined the list during the wait; re-reading")
            return
        }

        if badgeIDs.count > Self.remoteBadgeRefreshLimit {
            logRemoteHistory("\(badgeIDs.count) dives with fish/photo changes: badges refresh at the next membership change")
            badgeIDs = []
        }

        if !badgeIDs.isEmpty { refreshBadgeCaches(for: badgeIDs, photos: photoIDs) }
        if rebuilds {
            commitListRebuild()
            if !badgeIDs.isEmpty { scheduleAggregation(updateFishCaches: true) }
        } else if !rowIDs.isEmpty || !badgeIDs.isEmpty {
            patchSummaries(for: rowIDs.union(badgeIDs), badgesFromCaches: badgeIDs)
            let refilter = (!rowIDs.isEmpty && filtersAffectMembership)
                || (!badgeIDs.isEmpty && !filterMarineLife.isEmpty)
            if refilter {
                rebuildFilteredDives(dives: dives, selectedDiver: cachedSelectedDiver)
            } else {
                rederiveFilteredSummaries()
            }
            scheduleAggregation(updateFishCaches: !badgeIDs.isEmpty)
        }

        let outcome = rebuilds ? "full rebuild" : "patched \(rowIDs.union(badgeIDs).count) dive(s)"
        if merged || remoteRetriedAfterTimeout {
            let timedOut = !merged
            if let newestToken { advanceRemoteHistory(to: newestToken) } else { remoteRetriedAfterTimeout = false }
            clearNotedRemotePages()
            logRemoteHistory(outcome + (timedOut ? " (merge wait timed out)" : ""))
        } else {
            // Some dive may have been patched with pre-merge values. Keep the position and the
            // noted pages, and re-read this batch (the whole backlog) once; a second timeout
            // moves on (e.g. an unsaved local edit in an open sheet differs from the store).
            remoteRetriedAfterTimeout = true
            remoteHistoryRerunRequested = true
            logRemoteHistory(outcome + " (merge wait timed out; re-reading once)")
        }
    }

    /// Moves the history position forward. Every move ends any pending timeout retry.
    private func advanceRemoteHistory(to token: DefaultHistoryToken) {
        remoteHistoryToken = token
        remoteRetriedAfterTimeout = false
    }

    private func clearNotedRemotePages() {
        notedPages = NotedRemotePages()
    }

    /// A read-only context that reads committed values straight from the store.
    private func makeRemoteHistoryContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.author = Self.remoteHistoryAuthor
        return context
    }

    /// Fetches the given models through `fresh`, up to 200 per query. `missing` are identifiers
    /// the store does not have. A failed query falls back to one lookup per identifier, where an
    /// error only skips that identifier: an error is never reported as missing (callers treat
    /// missing dives as suspected deletions, which are re-verified before use anyway).
    private func fetchModels<T: PersistentModel>(
        _ pids: Set<PersistentIdentifier>,
        in fresh: ModelContext,
        onlyFetching properties: [PartialKeyPath<T>] = []
    ) async -> (found: [T], missing: Set<PersistentIdentifier>) {
        let all = Array(pids)
        var found: [T] = []
        var missing: Set<PersistentIdentifier> = []
        for start in stride(from: 0, to: all.count, by: 200) {
            let chunk = Array(all[start..<min(start + 200, all.count)])
            var descriptor = FetchDescriptor<T>(predicate: #Predicate { chunk.contains($0.persistentModelID) })
            descriptor.propertiesToFetch = properties
            do {
                let fetched = try fresh.fetch(descriptor)
                found.append(contentsOf: fetched)
                missing.formUnion(Set(chunk).subtracting(fetched.map(\.persistentModelID)))
            } catch {
                for pid in chunk {
                    var single = FetchDescriptor<T>(predicate: #Predicate { $0.persistentModelID == pid })
                    single.fetchLimit = 1
                    single.propertiesToFetch = properties
                    do {
                        if let model = try fresh.fetch(single).first { found.append(model) } else { missing.insert(pid) }
                    } catch {
                        logRemoteHistory("fresh fetch failed (\(error.localizedDescription)); skipping one check")
                    }
                }
            }
            // Let input events run between queries.
            await Task.yield()
        }
        return (found, missing)
    }

    /// Maps dives this app inserted to their permanent identifiers. `diveIDByPID` is built at a
    /// rebuild from the live dives; a dive inserted but not yet saved then is recorded under its
    /// temporary identifier, and saving it does not re-deliver the @Query (models compare by
    /// identity), so the map would keep the temporary one. The local save's history carries the
    /// permanent identifier; resolve it to the dive's UUID through the fresh context.
    private func remapLocallyInsertedDives(_ pids: Set<PersistentIdentifier>, in fresh: ModelContext) async {
        // Nothing to remap unless the map still holds a temporary identifier.
        guard diveIDByPID.keys.contains(where: { $0.storeIdentifier == nil }) else { return }
        let unknown = pids.filter { diveIDByPID[$0] == nil }
        guard !unknown.isEmpty else { return }
        let fetched: [Dive] = await fetchModels(unknown, in: fresh, onlyFetching: [\Dive.id]).found
        var pidByID = Dictionary(diveIDByPID.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var remapped = 0
        for dive in fetched {
            let id = dive.id
            guard diveByID[id] != nil else { continue }   // not listed yet: the @Query adds it
            if let old = pidByID[id] {
                #if DEBUG
                if old.storeIdentifier != nil {
                    logRemoteHistory("remapped an identifier that had a store identifier (expected temporary)")
                }
                #endif
                diveIDByPID[old] = nil
            }
            diveIDByPID[dive.persistentModelID] = id
            pidByID[id] = dive.persistentModelID
            remapped += 1
        }
        if remapped > 0 { logRemoteHistory("remapped \(remapped) locally inserted dive(s)") }
    }

    /// Fetches the history transactions after `token` (or, before the first one, after
    /// `baseline`), capped just above `remoteTransactionLimit`. A model context returns
    /// transactions in the order they occurred (SwiftData documentation), so a capped fetch
    /// holds the oldest ones and the next fetch continues after the newest of them.
    private nonisolated static func fetchHistoryTransactions(
        container: ModelContainer,
        after token: DefaultHistoryToken?,
        since baseline: Date
    ) throws -> [DefaultHistoryTransaction] {
        let context = ModelContext(container)
        context.author = remoteHistoryAuthor
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        descriptor.fetchLimit = UInt64(remoteTransactionLimit + 1)
        if let token {
            descriptor.predicate = #Predicate { $0.token > token }
        } else {
            descriptor.predicate = #Predicate { $0.timestamp > baseline }
        }
        return try context.fetchHistory(descriptor)
    }

    /// Sorts other devices' dive changes by what they require (see the table above).
    private func classifyRemoteHistory(_ transactions: [DefaultHistoryTransaction]) -> RemoteHistoryBatch {
        var batch = RemoteHistoryBatch()
        // The greatest token, independent of the order the results arrive in.
        batch.newestToken = transactions.map(\.token).max()
        batch.hasMoreTransactions = transactions.count > Self.remoteTransactionLimit

        var listKeys: Set<PartialKeyPath<Dive>> = [\Dive.timestamp, \Dive.diverName]
        switch sortOrder.field {
        case .date:       break
        // Depth sorts compare displayMaxDepth, which depends on the stored unit.
        case .depth:      listKeys.formUnion([\Dive.maxDepth, \Dive.importDistanceUnit])
        case .duration:   listKeys.insert(\Dive.duration)
        case .diveNumber: listKeys.insert(\Dive.diveNumber)
        }
        // Every stored attribute DiveSummary(from:) reads.
        let rowKeys: Set<PartialKeyPath<Dive>> = [
            \Dive.diveNumber, \Dive.timestamp, \Dive.diverName, \Dive.siteName, \Dive.location,
            \Dive.siteCountry, \Dive.siteLatitude, \Dive.siteLongitude, \Dive.exitLatitude,
            \Dive.exitLongitude, \Dive.maxDepth, \Dive.importDistanceUnit, \Dive.duration,
            \Dive.surfaceInterval, \Dive.rating, \Dive.buddies, \Dive.diveTypes, \Dive.tags,
            Dive.tanksDataKeyPath
        ]
        let badgeKeys: Set<PartialKeyPath<Dive>> = [\Dive.seenFish, \Dive.photosData]

        for transaction in transactions {
            if let author = transaction.author, author.hasPrefix(Self.appHistoryAuthorPrefix) {
                // This app's own save: already reflected through commit(_:affects:). Only its
                // dive inserts are kept, for remapping temporary identifiers.
                for change in transaction.changes {
                    if case .insert(let insert) = change, insert.changedPersistentIdentifier.entityName == "Dive" {
                        batch.localInsertedPIDs.insert(insert.changedPersistentIdentifier)
                    }
                }
                continue
            }
            for change in transaction.changes {
                switch change {
                case .insert:
                    // New dives (and new fish, whose dive also gets a seenFish update) reach the
                    // list through the @Query membership path.
                    continue
                case .update(let update):
                    if let sightUpdate = update as? DefaultHistoryUpdate<MarineSight> {
                        // Added or removed fish come with a seenFish update on their dive; a
                        // renamed fish changes only this row.
                        let renamed = sightUpdate.updatedAttributes.contains {
                            ($0 as PartialKeyPath<MarineSight>) == \MarineSight.name
                        }
                        if renamed { batch.renamedSightPIDs.insert(sightUpdate.changedPersistentIdentifier) }
                        continue
                    }
                    guard let diveUpdate = update as? DefaultHistoryUpdate<Dive> else { continue }
                    let pid = diveUpdate.changedPersistentIdentifier
                    let keys = Set(diveUpdate.updatedAttributes.map { $0 as PartialKeyPath<Dive> })
                    if !keys.isDisjoint(with: listKeys) {
                        batch.listPIDs.insert(pid)
                    } else if !keys.isDisjoint(with: rowKeys) {
                        batch.rowPIDs.insert(pid)
                    }
                    if !keys.isDisjoint(with: badgeKeys) { batch.badgePIDs.insert(pid) }
                    if keys.contains(\Dive.photosData) { batch.photoPIDs.insert(pid) }
                case .delete(let delete):
                    if delete.changedPersistentIdentifier.entityName == "Dive" {
                        batch.deletedPIDs.insert(delete.changedPersistentIdentifier)
                    }
                @unknown default:
                    continue
                }
            }
        }
        // Updates to dives added in this same batch are kept: a dive already in the list by the
        // time the batch applies is patched like any other; one not yet listed is skipped and
        // arrives through the @Query with its current values.
        return batch
    }

    /// Reads each given dive through `fresh`, which fetches the committed values straight from
    /// the store (grouped queries, see fetchModels). `missing` are dives the store no longer has;
    /// a fetch error only skips that dive's check (it must never be mistaken for a deletion).
    /// Photo counts are recorded only for dives whose photos changed (`photoPIDs`), because
    /// reading them loads every photo blob of the dive.
    private func freshExpectations(
        for pids: Set<PersistentIdentifier>,
        badgePIDs: Set<PersistentIdentifier>,
        photoPIDs: Set<PersistentIdentifier>,
        in fresh: ModelContext
    ) async -> (expectations: [PersistentIdentifier: RemoteDiveExpectation], missing: Set<PersistentIdentifier>) {
        let listed = pids.filter { diveIDByPID[$0] != nil }
        let fetched: (found: [Dive], missing: Set<PersistentIdentifier>) = await fetchModels(listed, in: fresh)
        var expectations: [PersistentIdentifier: RemoteDiveExpectation] = [:]
        for dive in fetched.found {
            let pid = dive.persistentModelID
            expectations[pid] = RemoteDiveExpectation(
                summary: DiveSummary(from: dive),
                fishNames: badgePIDs.contains(pid) ? Self.fishNames(of: dive) : nil,
                photoCount: photoPIDs.contains(pid) ? (dive.photosData?.count ?? 0) : nil
            )
        }
        return (expectations, fetched.missing)
    }

    /// Identifiers of every dive in the store (one query, no models loaded), or nil on error.
    private static func storeDiveIDs(in fresh: ModelContext) -> Set<PersistentIdentifier>? {
        (try? fresh.fetchIdentifiers(FetchDescriptor<Dive>())).map(Set.init)
    }

    /// Parent dives of the given MarineSight rows, as committed in the store (grouped queries).
    private func parentDivePIDs(ofSights sightPIDs: Set<PersistentIdentifier>,
                                in fresh: ModelContext) async -> Set<PersistentIdentifier> {
        guard !sightPIDs.isEmpty else { return [] }
        let sights: [MarineSight] = await fetchModels(sightPIDs, in: fresh).found
        return Set(sights.compactMap { $0.dive?.persistentModelID })
    }

    /// Waits (checking every 250 ms, up to 3 s) until no listed dive is gone from the store and
    /// the main context shows the committed values of every expected dive. Intermediate attempts
    /// only check the suspected dives (this batch's deletions, the expected dives, the current
    /// pending ones); before returning — on success or at the last attempt — every listed dive
    /// is compared with the store, because the caller's rebuild or re-filter then reads all of
    /// them with no await in between. Photo counts are compared only on that final check (they
    /// load every photo blob). Returns false on timeout; the caller then applies what the main
    /// context has, or defers if a deletion is pending.
    private func waitForMainContextMerge(
        of expectations: [PersistentIdentifier: RemoteDiveExpectation],
        deletedHints: Set<PersistentIdentifier>,
        in fresh: ModelContext
    ) async -> Bool {
        let lastAttempt = 12
        for attempt in 0...lastAttempt {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(250)) }
            let suspected = deletedHints.union(expectations.keys).union(pendingRemoteDeletedPIDs)
            updatePendingRemoteDeletions(checking: suspected, hints: deletedHints, in: fresh)
            if pendingRemoteDeletedPIDs.isEmpty && mainContextMatches(expectations, includingPhotos: false) {
                sweepRemoteDeletions(hints: deletedHints, in: fresh)
                if pendingRemoteDeletedPIDs.isEmpty && mainContextMatches(expectations, includingPhotos: true) {
                    return true
                }
            } else if attempt == lastAttempt {
                sweepRemoteDeletions(hints: deletedHints, in: fresh)
            }
        }
        return false
    }

    /// Updates `pendingRemoteDeletedPIDs` for the suspected dives only (one small query).
    /// Falls back to the full sweep if that query fails.
    private func updatePendingRemoteDeletions(checking suspected: Set<PersistentIdentifier>,
                                              hints: Set<PersistentIdentifier>,
                                              in fresh: ModelContext) {
        // A temporary identifier (no store identifier) was never in the store, so it cannot be a
        // merged deletion: it is a live dive inserted but not yet saved. Observed: temporary
        // identifiers carry no store identifier (PersistentIdentifier.isTemporary is iOS 27+).
        let candidates = Array(suspected.filter { diveIDByPID[$0] != nil && $0.storeIdentifier != nil })
        pendingRemoteDeletedPIDs = pendingRemoteDeletedPIDs.filter { diveIDByPID[$0] != nil }
        guard !candidates.isEmpty else { return }
        do {
            let present = Set(try fresh.fetchIdentifiers(
                FetchDescriptor<Dive>(predicate: #Predicate { candidates.contains($0.persistentModelID) })))
            for pid in candidates {
                if present.contains(pid) { pendingRemoteDeletedPIDs.remove(pid) } else { pendingRemoteDeletedPIDs.insert(pid) }
            }
        } catch {
            sweepRemoteDeletions(hints: hints, in: fresh)
        }
    }

    /// Sets `pendingRemoteDeletedPIDs` to every listed dive the store no longer has — deleted in
    /// this batch or not, including deletions merged during the wait. One identifier query over
    /// all dives; no Dive object is read.
    private func sweepRemoteDeletions(hints: Set<PersistentIdentifier>, in fresh: ModelContext) {
        guard let storeIDs = Self.storeDiveIDs(in: fresh) else {
            // Without the store's list, stay conservative: this batch's deletions and misses.
            pendingRemoteDeletedPIDs.formUnion(hints)
            pendingRemoteDeletedPIDs = pendingRemoteDeletedPIDs.filter { diveIDByPID[$0] != nil }
            return
        }
        pendingRemoteDeletedPIDs = Set(diveIDByPID.keys.filter {
            $0.storeIdentifier != nil && !storeIDs.contains($0)
        })
    }

    /// Precondition: `pendingRemoteDeletedPIDs` is empty (checked by the caller in the same
    /// synchronous step), so every dive read here still exists.
    private func mainContextMatches(_ expectations: [PersistentIdentifier: RemoteDiveExpectation],
                                    includingPhotos: Bool) -> Bool {
        for (pid, expected) in expectations {
            guard let id = diveIDByPID[pid], let dive = diveByID[id] else { continue }
            if DiveSummary(from: dive) != expected.summary { return false }
            if let names = expected.fishNames, Self.fishNames(of: dive) != names { return false }
            if includingPhotos, let count = expected.photoCount, (dive.photosData?.count ?? 0) != count { return false }
        }
        return true
    }

    private static func fishNames(of dive: Dive) -> [String] {
        (dive.seenFish ?? [])
            .map { $0.name.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// Refreshes the fish badge caches for the given dives, and the photo badge only for those
    /// whose photos changed (`photos`; reading photosData loads every photo blob). Faults these
    /// dives only, and publishes each cache with one assignment.
    private func refreshBadgeCaches(for ids: Set<UUID>, photos: Set<UUID>) {
        badgeCacheGeneration &+= 1
        var withFish = cachedDivesWithFish
        var withPhotos = cachedDivesWithPhotos
        for id in ids {
            guard let dive = diveByID[id] else { continue }
            let fish = dive.seenFish ?? []
            if fish.isEmpty { withFish.remove(id) } else { withFish.insert(id) }
            if photos.contains(id) {
                if dive.photosData?.isEmpty ?? true { withPhotos.remove(id) } else { withPhotos.insert(id) }
            }
            fishNamesByID[id] = fish.compactMap { sight -> String? in
                let n = sight.name.trimmingCharacters(in: .whitespaces)
                return n.isEmpty ? nil : n
            }
        }
        cachedDivesWithFish = withFish
        cachedDivesWithPhotos = withPhotos
    }

    private func logRemoteHistory(_ message: String) {
        #if DEBUG
        Self.remoteHistoryLogger.debug("🔄 remote changes: \(message, privacy: .public)")
        #endif
    }

    #if DEBUG
    private static let remoteHistoryLogger = Logger(subsystem: "com.bluedive.app", category: "RemoteHistory")
    #endif

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
            if let gas = filterGasType,
               !DiverFilter.matchesGas(DiveSummary.gasNames(of: dive), gas: gas, negate: filterGasTypeNegate) {
                return false
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

        // Sorting. Switching on the (field, direction) tuple keeps every combination
        // compiler-checked for exhaustiveness. `.diveNumber` collapses both
        // directions into one arm because it shares a single nil-last comparator
        // with a flipped `<`/`>` check. `.depth` collapses both directions for a
        // different reason: so both share the one decorate step below.
        switch (sortOrder.field, sortOrder.direction) {
        case (.date, .descending):
            break // @Query already delivers dives sorted by timestamp descending
        case (.date, .ascending):
            result.sort { $0.timestamp < $1.timestamp }

        // Depth is compared in *display* units so the ordering matches the numbers
        // shown in the rows, and so a library mixing metric and imperial imports
        // orders correctly. The depth-range filter above compares displayMaxDepth
        // for the same reason. Decorate-sort-undecorate: displayMaxDepth is a
        // computed property (unit conversion plus a UserPreferences read), so it's
        // evaluated once per dive here rather than repeatedly inside the comparator.
        case (.depth, let direction):
            var decorated = result.map { ($0, $0.displayMaxDepth) }
            switch direction {
            case .descending:
                decorated.sort { $0.1 > $1.1 }
            case .ascending:
                // maxDepth is a non-optional Double defaulting to 0 for dives with
                // no recorded depth — treat 0 as "unrecorded" and sort those last,
                // matching the diveNumber policy below, so they don't bury real
                // shallow dives.
                decorated.sort { lhs, rhs in
                    switch (lhs.1 == 0, rhs.1 == 0) {
                    case (false, false): return lhs.1 < rhs.1
                    case (true, false):  return false
                    case (false, true):  return true
                    case (true, true):   return false
                    }
                }
            }
            result = decorated.map { $0.0 }

        case (.duration, .descending):
            result.sort { $0.duration > $1.duration }
        case (.duration, .ascending):
            // Same "0 means unrecorded, sort last" policy as depth ascending above.
            result.sort { lhs, rhs in
                switch (lhs.duration == 0, rhs.duration == 0) {
                case (false, false): return lhs.duration < rhs.duration
                case (true, false):  return false
                case (false, true):  return true
                case (true, true):   return false
                }
            }

        // Dives without a dive number sort last in *both* directions, so the
        // unnumbered tail never splits the numbered run.
        case (.diveNumber, let direction):
            result.sort { lhs, rhs in
                switch (lhs.diveNumber, rhs.diveNumber) {
                case let (a?, b?): return direction == .ascending ? a < b : a > b
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
            for name in dive.seenFishNames where !name.isEmpty { marineLifeSet.insert(name) }

            yearSet.insert(dive.year)
            dive.gasNames.forEach { gasTypeSet.insert($0) }
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
