import SwiftUI
import MapKit
import SwiftData
import CoreLocation

private enum MapCoordinateMode: CaseIterable {
    case entry, exit
}

// Clustering radius as a fraction of the visible span: computeRawClusters merges a
// point into a cluster when it is within span / this value of the centroid, per axis.
private let clusterRadiusDivisor: Double = 20.0

// Bounding-box diagonal below which a cluster's dives are treated as literally the
// same coordinate, so no zoom could ever separate them and the list is the only
// useful outcome. Deliberately 1 m, not the old 10 m: two dives 8 m apart are genuinely
// distinct points and must at least get a zoom attempt. Deciding whether that attempt
// *achieved* anything is no longer predicted up front — handleClusterTap zooms and then
// verifies against the real recluster (see verifyZoomSplit).
private let sameSpotThresholdMeters: Double = 1.0

// Degenerate-span clamp only. Its sole job is stopping a zero-width cluster (all dives
// on one axis) from producing a zero or absurdly tiny target span; it is NOT a
// prediction input and must never appear in a "would this still merge?" calculation.
// ~5 m of latitude, far below any realistic dive spacing, so — unlike the old 0.0015
// floor, which was the practical target for nearly every real cluster — it effectively
// never becomes the target span in practice.
private let deepStopZoomSpan: Double = 0.00005

// Zoom ratio below which a span change counts as a real zoom. Shared by the passive
// recluster gate and handleClusterTap's "is this zoom perceptible?" test.
private let zoomPerceptibleRatio: Double = 0.7

// Largest pin count a recluster may animate. The soft-fade between pin sets is a
// deliberate UX touch for the common case (a handful of pins regrouping), but
// withAnimation makes SwiftUI diff and animate every annotation insert/remove — at tight
// zoom over a large library the cluster count approaches the dive count, and animating
// thousands of annotation changes is pure main-thread cost for a fade nobody can follow.
// Above this, assign the new set directly (hard cut, the pre-soft-fade behaviour).
private let maxAnimatedClusterCount: Int = 300

struct DiveMapView: View {
    @Environment(DiveStore.self) private var store
    @Query(sort: \Gear.name) private var allGear: [Gear]
    @Query(sort: \Certification.issueDate, order: .reverse) private var allCertifications: [Certification]
    @Query private var allInsurances: [DivingInsurance]
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedDive: Dive?
    @State private var mapStyle: MapStyle = .standard(elevation: .realistic)
    @State private var locationManager = CLLocationManager()
    @State private var coordinateMode: MapCoordinateMode = .entry

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
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""
    @State private var prefs = UserPreferences.shared

    private var activeFilterCount: Int {
        var count = 0
        if filterYear != nil                         { count += 1 }
        if filterGasType != nil                      { count += 1 }
        if filterMinDepth > 0 || filterMaxDepth > 0  { count += 1 }
        if filterMinRating > 0                       { count += 1 }
        if filterCountry != nil                      { count += 1 }
        if filterDiveType != nil                     { count += 1 }
        if filterTag != nil                          { count += 1 }
        if !filterMarineLife.isEmpty                 { count += 1 }
        return count
    }

    // MARK: - Clustering & Snapshot Cache

    // Gate-quantized span: only advances when a zoom crosses the recluster threshold,
    // so small pan-induced span drift doesn't churn the clusters. Drives reclustering.
    @State private var currentSpan: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)
    // The camera's actual span, updated on every onMapCameraChange(.onEnd) event — still
    // fresher than currentSpan's gated value. Tap handling must use this rather than
    // currentSpan, whose lag is what let a cluster tap become a permanent no-op (see
    // handleClusterTap).
    @State private var liveSpan: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)
    // Set right before a tap-triggered zoom starts; cleared (and the recluster
    // performed) by the next onMapCameraChange event, which carries the real,
    // MapKit-delivered span rather than the requested one handleClusterTap
    // computed. Zooming to a *requested* span and reclustering against it
    // immediately caused two problems: (1) the pins split within a couple
    // frames while the camera was still barely moving — a visible pop, well
    // before the 0.35s animation visually finished — and (2) MapKit aspect-fits
    // requested regions to the view, so the real delivered span usually differs
    // from the requested one; writing the requested span into currentSpan made
    // the passive gate below fire *again* once the real settle event arrived,
    // causing a second recluster ("double regroup") a moment after the first.
    @State private var awaitingZoomRecluster = false
    // Safety net for the (very unlikely) case where MapKit delivers no camera
    // event at all after an armed zoom, which would otherwise leave the pins
    // permanently un-reclustered. Held so a second tap can cancel a pending
    // watchdog from a previous tap.
    @State private var zoomReclusterWatchdog: Task<Void, Never>? = nil
    // Member IDs of the cluster whose tap armed the pending zoom. After the zoom's
    // recluster completes, verifyZoomSplit checks whether a cluster with exactly this
    // membership still exists: if it does, the zoom demonstrably split nothing and the
    // list is shown. Same UUID identity the clusterer itself uses (DiveCoordPoint.id /
    // store.diveByID), so there is only ever one identity scheme in play here.
    @State private var pendingZoomMemberIDs: Set<UUID> = []
    @State private var clusterDives: [Dive]? = nil
    @State private var cachedClusters: [DiveCluster] = []
    @State private var cachedUniqueDivers: [String] = []
    @State private var clusteringTask: Task<Void, Never>? = nil
    @State private var isFilterTaskActive = false
    @State private var filterOptions = MapFilterOptions()
    // Cached result of the last filter pass; camera zoom re-clusters from here.
    @State private var filteredCoordPoints: [DiveCoordPoint] = []

    private struct DiveCluster: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let dives: [Dive]
        // Whether every dive in the cluster belongs to the same named diver — drives the
        // pin's tint (cyan vs. orange). Computed once per cluster during the filter/
        // recluster pass — never from `body` — so per-render pin rendering stays O(1)
        // even for large single-site clusters.
        let isSingleDiver: Bool
    }

    // True when every dive in the cluster shares one non-empty diver name.
    private nonisolated static func isSingleDiverCluster(for dives: [Dive]) -> Bool {
        let names = Set(dives.map { $0.diverName.trimmingCharacters(in: .whitespaces) })
        guard names.count == 1, let name = names.first else { return false }
        return !name.isEmpty
    }

    // Normalizes longitude into [-180, 180) so dives near the antimeridian
    // don't land in unrelated clusters.
    private func normalizedLongitude(_ lon: Double) -> Double {
        var l = lon.truncatingRemainder(dividingBy: 360.0)
        if l >= 180.0 { l -= 360.0 }
        if l < -180.0 { l += 360.0 }
        return l
    }

    // MARK: - Cached Filter Options

    private struct MapFilterOptions {
        var years: [Int] = []
        var gasTypes: [String] = []
        var countries: [String] = []
        var diveTypes: [String] = []
        var tags: [String] = []
        var marineLife: [String] = []
    }

    // MARK: - Background Clustering Support

    private struct DiveCoordPoint: Sendable {
        let id: UUID
        let lat: Double
        let lon: Double
    }

    private struct RawClusterResult: Sendable {
        let memberIDs: [UUID]
        let centroidLat: Double
        let centroidLon: Double
    }

    // MARK: - Cluster Identity

    // Identity derived from every member, not just the lowest UUID: the previous
    // "min UUID + count" form collided whenever two distinct clusters shared their
    // lowest-UUID member and their size, which confused ForEach identity. Folded
    // order-independently so a large single-site cluster doesn't have to sort and
    // concatenate thousands of UUID strings on every recluster.
    private nonisolated static func clusterID(for memberIDs: [UUID]) -> String {
        var high: UInt64 = 0
        var low: UInt64 = 0
        for id in memberIDs {
            withUnsafeBytes(of: id.uuid) { raw in
                high ^= raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
                low  ^= raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            }
        }
        return String(format: "%016lx%016lx_%d", high, low, memberIDs.count)
    }

    // MARK: - State Rebuilders

    private func rebuildUniqueDivers() {
        cachedUniqueDivers = DiverFilter.uniqueDivers(
            in: store.dives, gear: allGear, certifications: allCertifications, insurances: allInsurances
        )
    }

    // Builds filter sheet options from the store's cached summaries (no SwiftData access).
    // Only includes dives that have valid coordinates in the current mode.
    private func rebuildFilterOptions() {
        var years = Set<Int>()
        var gasTypes = Set<String>()
        var countries = Set<String>()
        var diveTypes = Set<String>()
        var tags = Set<String>()
        var marineLife = Set<String>()
        for snap in store.cachedSummaries {
            let lat: Double?
            let lon: Double?
            switch coordinateMode {
            case .entry: (lat, lon) = (snap.siteLatitude, snap.siteLongitude)
            case .exit:  (lat, lon) = (snap.exitLatitude,  snap.exitLongitude)
            }
            guard let lat, let lon, !(lat == 0 && lon == 0),
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            else { continue }
            years.insert(snap.year)
            gasTypes.insert(snap.gasType)
            if let c = snap.siteCountry, !c.isEmpty { countries.insert(c) }
            snap.diveTypes.forEach    { diveTypes.insert($0) }
            snap.tags.forEach         { tags.insert($0) }
            snap.seenFishNames.forEach { marineLife.insert($0) }
        }
        filterOptions = MapFilterOptions(
            years: Array(years).sorted(by: >),
            gasTypes: Array(gasTypes).sorted(),
            countries: Array(countries).sorted(),
            diveTypes: Array(diveTypes).sorted(),
            tags: Array(tags).sorted(),
            marineLife: Array(marineLife).sorted()
        )
    }

    // Full rebuild triggered by dives changes. Gear/cert/insurance changes use
    // rebuildUniqueDivers() only — they don't affect the map pins.
    private func rebuildMapState() {
        rebuildUniqueDivers()
        rebuildFilterOptions()
        scheduleFilterAndCluster()
    }

    // MARK: - Scheduling

    // Re-filters the snapshot array on a background thread, then clusters.
    // Call this when dives data or any filter parameter changes.
    private func scheduleFilterAndCluster() {
        clusteringTask?.cancel()
        let snapshots = store.cachedSummaries
        guard !snapshots.isEmpty else {
            filteredCoordPoints = []
            cachedClusters = []
            isFilterTaskActive = false
            return
        }
        let mode        = coordinateMode
        let diver       = selectedDiver
        let fYear       = filterYear
        let fYearNeg    = filterYearNegate
        let fGas        = filterGasType
        let fGasNeg     = filterGasTypeNegate
        let fMinDepth   = filterMinDepth
        let fMaxDepth   = filterMaxDepth
        let fRating     = filterMinRating
        let fCountry    = filterCountry
        let fCountryNeg = filterCountryNegate
        let fDiveType   = filterDiveType
        let fDiveTypeNeg = filterDiveTypeNegate
        let fTag        = filterTag
        let fMarineLife = filterMarineLife
        let fMarineLifeMode = filterMarineLifeMode
        let span        = currentSpan
        let byID        = store.diveByID
        let displayInFeet = prefs.depthUnit == .feet
        let depthFactor = DepthUnit.metersToFeetFactor   // capture on MainActor

        isFilterTaskActive = true
        clusteringTask = Task {
            let (points, rawResults) = await Task.detached(priority: .userInitiated) {
                let filtered = DiveMapView.filterSnapshots(
                    snapshots,
                    coordinateMode: mode,
                    selectedDiver: diver,
                    filterYear: fYear, filterYearNegate: fYearNeg,
                    filterGasType: fGas, filterGasTypeNegate: fGasNeg,
                    filterMinDepth: fMinDepth, filterMaxDepth: fMaxDepth,
                    filterMinRating: fRating,
                    filterCountry: fCountry, filterCountryNegate: fCountryNeg,
                    filterDiveType: fDiveType, filterDiveTypeNegate: fDiveTypeNeg,
                    filterTag: fTag,
                    filterMarineLife: fMarineLife, filterMarineLifeMode: fMarineLifeMode,
                    displayInFeet: displayInFeet,
                    depthFactor: depthFactor
                )
                let raw = DiveMapView.computeRawClusters(points: filtered, span: span)
                return (filtered, raw)
            }.value
            guard !Task.isCancelled else { return }
            filteredCoordPoints = points
            cachedClusters = rawResults.compactMap { raw in
                let dives = raw.memberIDs.compactMap { byID[$0] }
                guard !dives.isEmpty else { return nil }
                return DiveCluster(
                    id: DiveMapView.clusterID(for: raw.memberIDs),
                    coordinate: CLLocationCoordinate2D(latitude: raw.centroidLat, longitude: raw.centroidLon),
                    dives: dives,
                    isSingleDiver: DiveMapView.isSingleDiverCluster(for: dives)
                )
            }.sorted { $0.id < $1.id }
            isFilterTaskActive = false
            // If the camera span changed while filtering, recluster immediately so
            // pins reflect the current zoom level without waiting for the next event.
            if currentSpan.latitudeDelta != span.latitudeDelta
                || currentSpan.longitudeDelta != span.longitudeDelta {
                scheduleRecluster()
            }
        }
    }

    // Re-clusters the already-filtered coord points when the camera span changes.
    // Skips the O(n) filter pass — only the O(k²) cluster pass re-runs (k ≤ n).
    // Defers to the in-flight filter task if one is active: the filter task will
    // call scheduleRecluster() itself after it completes with the latest span.
    private func scheduleRecluster() {
        guard !isFilterTaskActive else { return }
        let points = filteredCoordPoints
        guard !points.isEmpty else { return }
        clusteringTask?.cancel()
        let span = currentSpan
        let byID = store.diveByID

        clusteringTask = Task {
            let rawResults = await Task.detached(priority: .userInitiated) {
                DiveMapView.computeRawClusters(points: points, span: span)
            }.value
            guard !Task.isCancelled else { return }
            // Computed once, outside any animation block, so neither branch below
            // recomputes it.
            let newClusters: [DiveCluster] = rawResults.compactMap { raw in
                let dives = raw.memberIDs.compactMap { byID[$0] }
                guard !dives.isEmpty else { return nil }
                return DiveCluster(
                    id: DiveMapView.clusterID(for: raw.memberIDs),
                    coordinate: CLLocationCoordinate2D(latitude: raw.centroidLat, longitude: raw.centroidLon),
                    dives: dives,
                    isSingleDiver: DiveMapView.isSingleDiverCluster(for: dives)
                )
            }.sorted { $0.id < $1.id }
            // Soft-fade the pin change instead of hard-popping the new set in — but only
            // while the set is small. Animating the assignment makes SwiftUI diff and
            // animate every annotation insert/remove; past a few hundred pins that is real
            // main-thread work on every recluster, and the fade is imperceptible anyway.
            if max(newClusters.count, cachedClusters.count) <= maxAnimatedClusterCount {
                withAnimation(.easeInOut(duration: 0.2)) {
                    cachedClusters = newClusters
                }
            } else {
                cachedClusters = newClusters
            }
        }
    }

    // MARK: - Pure Background Functions

    // Filters a Sendable snapshot array for coordinates and all filter parameters.
    // No SwiftData access — safe to call from background threads.
    private nonisolated static func filterSnapshots(
        _ snapshots: [DiveSummary],
        coordinateMode: MapCoordinateMode,
        selectedDiver: String,
        filterYear: Int?, filterYearNegate: Bool,
        filterGasType: String?, filterGasTypeNegate: Bool,
        filterMinDepth: Double, filterMaxDepth: Double,
        filterMinRating: Int,
        filterCountry: String?, filterCountryNegate: Bool,
        filterDiveType: String?, filterDiveTypeNegate: Bool,
        filterTag: String?,
        filterMarineLife: [String], filterMarineLifeMode: FilterMarineLifeMode,
        displayInFeet: Bool,
        depthFactor: Double
    ) -> [DiveCoordPoint] {
        let marineLifeLowercased = filterMarineLife.map { $0.lowercased() }
        return snapshots.compactMap { snap in
            let lat: Double?
            let lon: Double?
            switch coordinateMode {
            case .entry: (lat, lon) = (snap.siteLatitude, snap.siteLongitude)
            case .exit:  (lat, lon) = (snap.exitLatitude,  snap.exitLongitude)
            }
            guard let lat, let lon, !(lat == 0 && lon == 0),
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            else { return nil }

            if !selectedDiver.isEmpty, snap.diverName != selectedDiver { return nil }

            if let year = filterYear {
                if filterYearNegate { if snap.year == year { return nil } }
                else                { if snap.year != year { return nil } }
            }
            if let gas = filterGasType {
                if gas.isEmpty          { if !snap.gasType.isEmpty { return nil } }
                else if filterGasTypeNegate { if snap.gasType == gas { return nil } }
                else                    { if snap.gasType != gas { return nil } }
            }
            if filterMinDepth > 0 || filterMaxDepth > 0 {
                let storedInFeet = snap.importDistanceUnit == "feet"
                let depth: Double
                if displayInFeet {
                    depth = storedInFeet ? snap.maxDepth : snap.maxDepth * depthFactor
                } else {
                    depth = storedInFeet ? snap.maxDepth / depthFactor : snap.maxDepth
                }
                if filterMinDepth > 0, filterMaxDepth > 0 {
                    let lo = Swift.min(filterMinDepth, filterMaxDepth)
                    let hi = Swift.max(filterMinDepth, filterMaxDepth)
                    if depth < lo || depth > hi { return nil }
                } else if filterMinDepth > 0 { if depth < filterMinDepth { return nil } }
                else if filterMaxDepth > 0   { if depth > filterMaxDepth { return nil } }
            }
            if filterMinRating > 0, snap.rating < filterMinRating { return nil }
            if let country = filterCountry {
                if country.isEmpty    { if let c = snap.siteCountry, !c.isEmpty { return nil } }
                else if filterCountryNegate { if let c = snap.siteCountry, c == country { return nil } }
                else                  { guard let c = snap.siteCountry, c == country else { return nil } }
            }
            if let diveType = filterDiveType {
                if diveType.isEmpty        { if !snap.diveTypes.isEmpty { return nil } }
                else if filterDiveTypeNegate { if snap.diveTypes.contains(diveType) { return nil } }
                else                       { if !snap.diveTypes.contains(diveType) { return nil } }
            }
            if let tag = filterTag {
                if tag.isEmpty { if !snap.tags.isEmpty { return nil } }
                else           { if !snap.tags.contains(tag) { return nil } }
            }
            if !marineLifeLowercased.isEmpty {
                switch filterMarineLifeMode {
                case .any:
                    if !marineLifeLowercased.contains(where: { ml in
                        snap.seenFishNames.contains { $0.lowercased() == ml }
                    }) { return nil }
                case .all:
                    if !marineLifeLowercased.allSatisfy({ ml in
                        snap.seenFishNames.contains { $0.lowercased() == ml }
                    }) { return nil }
                }
            }

            var normLon = lon.truncatingRemainder(dividingBy: 360.0)
            if normLon >= 180.0  { normLon -= 360.0 }
            if normLon < -180.0  { normLon += 360.0 }
            return DiveCoordPoint(id: snap.id, lat: lat, lon: normLon)
        }
    }

    // Pure function — no SwiftData access, safe to call from background tasks.
    private nonisolated static func computeRawClusters(
        points: [DiveCoordPoint], span: MKCoordinateSpan
    ) -> [RawClusterResult] {
        let radiusLat = max(span.latitudeDelta, 0.00001) / clusterRadiusDivisor
        let baseLonRadius = max(span.longitudeDelta, 0.00001) / clusterRadiusDivisor
        struct WorkingCluster {
            var sumLat: Double
            var sumLon: Double
            var ids: [UUID]
            var centroidLat: Double { sumLat / Double(ids.count) }
            var centroidLon: Double { sumLon / Double(ids.count) }
        }
        var working: [WorkingCluster] = []
        for point in points {
            let latCos = max(cos(point.lat * .pi / 180.0), 0.01)
            let radiusLon = baseLonRadius / latCos
            var merged = false
            for i in working.indices {
                if abs(point.lat - working[i].centroidLat) <= radiusLat &&
                   abs(point.lon - working[i].centroidLon) <= radiusLon {
                    working[i].sumLat += point.lat
                    working[i].sumLon += point.lon
                    working[i].ids.append(point.id)
                    merged = true
                    break
                }
            }
            if !merged {
                working.append(WorkingCluster(sumLat: point.lat, sumLon: point.lon, ids: [point.id]))
            }
        }
        return working.map { cluster in
            RawClusterResult(
                memberIDs: cluster.ids,
                centroidLat: cluster.sumLat / Double(cluster.ids.count),
                centroidLon: cluster.sumLon / Double(cluster.ids.count)
            )
        }
    }

    // MARK: - Change Observers (split to avoid Swift type-checker timeouts)

    @ViewBuilder
    private var mapObserversA: some View {
        Color.clear
            .onChange(of: store.cachedSummaries, initial: true) { _, _ in rebuildMapState() }
            // Gear/cert/insurance only affect the diver picker, not map pins.
            .onChange(of: allGear)           { _, _ in rebuildUniqueDivers() }
            .onChange(of: allCertifications) { _, _ in rebuildUniqueDivers() }
            .onChange(of: allInsurances)     { _, _ in rebuildUniqueDivers() }
    }

    @ViewBuilder
    private var mapObserversB: some View {
        Color.clear
            .onChange(of: coordinateMode) { _, _ in
                // Coordinate mode switches which lat/lon pair is used; rebuild
                // filter options (geolocated set may change) and re-filter.
                rebuildFilterOptions()
                scheduleFilterAndCluster()
            }
            .onChange(of: prefs.depthUnit) { _, _ in
                scheduleFilterAndCluster()
            }
    }

    @ViewBuilder
    private var mapObservers: some View {
        mapObserversA
        mapObserversB
    }

    @ViewBuilder
    private var filterObserversA: some View {
        Color.clear
            .onChange(of: selectedDiver)       { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterYear)          { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterYearNegate)    { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterGasType)       { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterGasTypeNegate) { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterMinDepth)      { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterMaxDepth)      { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterMinRating)     { _, _ in scheduleFilterAndCluster() }
    }

    @ViewBuilder
    private var filterObserversB: some View {
        Color.clear
            .onChange(of: filterCountry)        { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterCountryNegate)  { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterDiveType)       { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterDiveTypeNegate) { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterTag)            { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterMarineLife)     { _, _ in scheduleFilterAndCluster() }
            .onChange(of: filterMarineLifeMode) { _, _ in scheduleFilterAndCluster() }
    }

    @ViewBuilder
    private var filterObservers: some View {
        filterObserversA
        filterObserversB
    }

    // Re-clusters against the freshest camera span and then *verifies*, rather than
    // predicts, whether the tap-triggered zoom actually split the tapped cluster.
    //
    // The old code predicted the outcome up front with a bounding-box-vs-radius test
    // (`wouldReMerge`), which was provably wrong in real data: computeRawClusters merges
    // points one at a time against a *shifting running centroid* (a first-fit chain), so
    // a group far wider than the merge radius can still chain-merge into one cluster.
    // e.g. dives at 0/8/12/16/20 m with an 8.3 m radius: 8 m joins 0 m (centroid 4 m),
    // 12 m is 8 m from that new centroid so it joins too (centroid 6.7 m), and so on —
    // a 20 m-wide group survives a test that said it must split. The user saw a zoom
    // that visually changed nothing, then a second tap that fell through to the list.
    //
    // So: zoom first, let the real clusterer answer, and only then decide. Shared by the
    // real camera-settle path and the watchdog so both resolve identically.
    private func verifyZoomSplit() {
        let expected = pendingZoomMemberIDs
        pendingZoomMemberIDs = []
        // scheduleRecluster() early-returns without creating a task when a filter pass is
        // already in flight or there are no points — the same two conditions checked here,
        // synchronously on the MainActor, so this mirrors it exactly. In that case
        // clusteringTask is either nil or some *other* piece of work, and there is no zoom
        // recluster whose result we could verify. Acceptable edge case: the in-flight
        // filter task reclusters with the current span on its own when it finishes, and
        // the user can simply tap again. Still recluster, just skip the verification.
        let willCreateTask = !isFilterTaskActive && !filteredCoordPoints.isEmpty
        scheduleRecluster()
        guard !expected.isEmpty, willCreateTask, let task = clusteringTask else { return }
        Task {
            await task.value
            // The recluster we were waiting on was cancelled by a newer one (a filter
            // change or another camera event), so it never wrote cachedClusters: what's
            // there is the pre-zoom set, which trivially still contains the tapped
            // cluster and would produce a bogus "it didn't split" verdict. The newer
            // recluster's pins are the visible outcome instead.
            guard !task.isCancelled else { return }
            // A newer tap armed another zoom while this recluster ran: its outcome
            // supersedes ours, so don't pop a list over the top of a camera move.
            guard !Task.isCancelled, !awaitingZoomRecluster else { return }
            // Did the tapped cluster survive the zoom intact? If yes, the zoom split
            // nothing, so fall back to the list — a tap must always produce a visible
            // outcome. If no match, it split (or membership changed), and the visual
            // separation on the map is the outcome; do nothing further.
            // Cheap count check first: `&&` short-circuits, so the Set allocation only
            // happens for the handful of clusters that could possibly match. Without it,
            // every cluster in the map — potentially the whole filtered dataset at
            // 10 000+ dives — pays for a Set build during this single lookup.
            guard let survivor = cachedClusters.first(where: {
                $0.dives.count == expected.count && Set($0.dives.map(\.id)) == expected
            })
            else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                clusterDives = survivor.dives
            }
        }
    }

    private func handleClusterTap(_ cluster: DiveCluster) {
        // A previous tap's zoom is still in flight: the camera is mid-animation, so
        // liveSpan is stale and any decision made from it would be computed against a
        // span the user is no longer looking at. Worse, arming a second zoom would
        // overwrite pendingZoomMemberIDs and orphan the first tap's verification. Let the
        // real camera event (or the watchdog) resolve the pending zoom first.
        guard !awaitingZoomRecluster else { return }

        let lats: [Double]
        let lons: [Double]
        switch coordinateMode {
        case .entry:
            lats = cluster.dives.compactMap { $0.siteLatitude }
            lons = cluster.dives.compactMap { $0.siteLongitude }.map { normalizedLongitude($0) }
        case .exit:
            lats = cluster.dives.compactMap { $0.exitLatitude }
            lons = cluster.dives.compactMap { $0.exitLongitude }.map { normalizedLongitude($0) }
        }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }

        let latSpread = maxLat - minLat
        let lonSpread = maxLon - minLon

        // "Same spot" test in meters (robust at all latitudes). Only literally-identical
        // coordinates short-circuit here; everything else at least gets a zoom attempt,
        // whose success is then verified for real instead of forecast.
        let corner1 = CLLocation(latitude: minLat, longitude: minLon)
        let corner2 = CLLocation(latitude: maxLat, longitude: maxLon)
        if corner1.distance(from: corner2) < sameSpotThresholdMeters {
            withAnimation(.easeInOut(duration: 0.35)) {
                clusterDives = cluster.dives
            }
            return
        }

        // Candidate zoom target: the cluster's bounding box plus padding, clamped only
        // against a degenerate zero-width span.
        let latDelta = max(latSpread * 2.5, deepStopZoomSpan)
        let lonDelta = max(lonSpread * 2.5, deepStopZoomSpan)

        // Would the move even be visible? Measured against the live camera span, not the
        // lagging gate-quantized currentSpan. This is the check that fixes the original
        // permanent no-op: re-requesting a region essentially identical to the current
        // one changes nothing, fires no camera event, and reclusters nothing. If we can't
        // get meaningfully closer, the list is the only remaining useful outcome.
        let zoomImperceptible = latDelta >= liveSpan.latitudeDelta * zoomPerceptibleRatio
            && lonDelta >= liveSpan.longitudeDelta * zoomPerceptibleRatio
        if zoomImperceptible {
            withAnimation(.easeInOut(duration: 0.35)) {
                clusterDives = cluster.dives
            }
            return
        }

        let centerLat = (minLat + maxLat) / 2.0
        let centerLon = (minLon + maxLon) / 2.0
        let targetSpan = MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)

        // Arm the recluster instead of performing it here, and let the camera's own
        // settle event (onMapCameraChange, .onEnd) do the work. That event is the only
        // trustworthy "the camera actually finished moving" signal, and it carries the
        // span MapKit really delivered — which, because MapKit aspect-fits a requested
        // region to the view, is normally not `targetSpan`. Reclustering here against
        // `targetSpan` split the pins a couple of frames into the 0.35s move (a visible
        // pop) and then let the passive gate fire a second time on the real event (a
        // "double regroup"). Armed before withAnimation purely for clarity: withAnimation
        // runs its body synchronously, so no camera event can be delivered until this
        // whole function has returned either way.
        //
        // Capture the tapped cluster's membership before the camera moves: after the
        // recluster, verifyZoomSplit looks for a cluster with exactly this membership to
        // decide whether the zoom achieved a visual split or not.
        pendingZoomMemberIDs = Set(cluster.dives.map(\.id))
        awaitingZoomRecluster = true
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: targetSpan
            ))
        }

        // Safety net only: if MapKit somehow delivers no camera event for this zoom, the
        // pins would stay merged forever. The real event is the primary mechanism and
        // must always win this race, so the delay only needs to be comfortably longer
        // than a camera move — it deliberately does not try to track one. Note that
        // MapKit runs the transition itself and ignores the 0.35s requested above:
        // instrumented on device, the settle event lands at ~1.05s after the tap, so a
        // 1.0s watchdog fired ~40ms *early* and pre-empted the real event every time.
        // 3s leaves a wide margin. Cancels any watchdog left over from a previous tap
        // (the guard at the top of this function means one can only linger after its
        // zoom was already resolved).
        zoomReclusterWatchdog?.cancel()
        zoomReclusterWatchdog = Task {
            try? await Task.sleep(for: .seconds(3.0))
            guard !Task.isCancelled, awaitingZoomRecluster else { return }
            awaitingZoomRecluster = false
            zoomReclusterWatchdog = nil
            // No real event arrived, so liveSpan is the freshest camera span we have.
            // Same verify-after-recluster resolution as the real-event path, so a tap
            // still produces a visible outcome even when MapKit goes silent.
            currentSpan = liveSpan
            verifyZoomSplit()
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // No `selection:` binding: MapKit's native annotation-selection gesture
                // competes with the cluster pins' nested onTapGesture and could swallow
                // a tap near a cluster's anchor before handleClusterTap ever ran. Both
                // pin kinds now go through the same explicit tap gesture instead.
                Map(position: $cameraPosition) {
                    // One pass over cachedClusters: single-dive and multi-dive pins
                    // branch inside the loop rather than each re-scanning the array.
                    ForEach(cachedClusters) { cluster in
                        if cluster.dives.count == 1, let dive = cluster.dives.first {
                            // Single-dive pins keep MapKit's normal collision-avoidance
                            // (.automatic): their caption is a site name, which is neither
                            // shortenable (truncating "Blue H…" is just confusing) nor costly
                            // to occasionally hide (the name is still one tap away, and the pin
                            // still marks the spot).
                            //
                            // DiveMapPin's triangle pointer tapers to a point at its flat
                            // bottom edge, not its geometric center — anchor there explicitly
                            // so the visual "tip" actually marks the coordinate, matching the
                            // anchor convention used by the Site Details map and GPS picker.
                            Annotation(
                                dive.siteName,
                                coordinate: cluster.coordinate,
                                anchor: .bottom
                            ) {
                                DiveMapPin(dive: dive, isSelected: selectedDive?.id == dive.id)
                                    .onTapGesture {
                                        selectedDive = dive
                                    }
                                    .accessibilityElement()
                                    // A dive logged without a site name would otherwise
                                    // announce nothing at all for this pin.
                                    .accessibilityLabel(dive.siteName.isEmpty ? Text("Dive Site") : Text(verbatim: dive.siteName))
                                    .accessibilityAddTraits(.isButton)
                                    // onTapGesture isn't reliably fired by VoiceOver's
                                    // activate gesture; this makes double-tap select the
                                    // dive now that native selection is gone.
                                    .accessibilityAction { selectedDive = dive }
                            }
                        } else {
                            // Cluster pins always show their count directly in the badge (no
                            // more initials-vs-count split — see DiveMapClusterPin), so there's
                            // no caption to render and nothing for MapKit's title-collision
                            // avoidance to fight; hence no label at all here, rather than the
                            // title-taking initializer other pins use.
                            Annotation(coordinate: cluster.coordinate, anchor: .bottom) {
                                DiveMapClusterPin(count: cluster.dives.count, isSingleDiver: cluster.isSingleDiver)
                                    .onTapGesture {
                                        handleClusterTap(cluster)
                                    }
                                    .accessibilityElement()
                                    .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("%@ dives at this location", bundle: .forAppLanguage(), comment: "Number of dives at a cluster location"), Double(cluster.dives.count).localizedString(decimals: 0))))
                                    .accessibilityAddTraits(.isButton)
                                    // onTapGesture isn't reliably fired by VoiceOver's activate
                                    // gesture; this makes double-tap open the cluster.
                                    .accessibilityAction { handleClusterTap(cluster) }
                            } label: {
                                EmptyView()
                            }
                        }
                    }
                    UserAnnotation()
                }
                .mapStyle(mapStyle)
                // Tap empty water to dismiss whichever card is up. Removing the
                // `selection:` binding above also removed MapKit's free "tap outside an
                // annotation deselects" behaviour, leaving the card's X button as the only
                // way out. This restores it without re-introducing that competing gesture:
                // the tap lives on the Map itself, not on a full-screen overlay (which
                // would intercept pan/zoom and the pins' own taps). SwiftUI routes a tap
                // that lands on an annotation's content to that annotation's
                // `.onTapGesture` first, so only a tap on bare map reaches this handler —
                // pin and cluster selection above are untouched.
                .onTapGesture {
                    // No card showing: do nothing at all, so an ordinary tap on the map
                    // doesn't kick off a pointless animation transaction.
                    guard selectedDive != nil || clusterDives != nil else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        selectedDive = nil
                        clusterDives = nil
                    }
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    // Only re-cluster when the user has actually zoomed. Panning
                    // (especially north/south) produces small Mercator-projection
                    // span drift that we want to ignore so clusters stay stable.
                    // Sub-threshold zooms naturally accumulate because the
                    // baseline only advances when we cross the threshold.
                    let newSpan = context.region.span
                    // Tracked unconditionally: tap handling needs the camera's real
                    // span, which the gated baseline below deliberately lags behind.
                    liveSpan = newSpan
                    // A tap-triggered zoom is pending: this event *is* its completion, so
                    // resolve it here with the real delivered span and skip the ratio gate
                    // entirely. The requested-vs-delivered span difference could otherwise
                    // make the gate either miss this zoom or double-fire on it.
                    // verifyZoomSplit reclusters against the delivered span and then checks
                    // whether the tapped cluster actually came apart, falling back to the
                    // list if it did not. Mutually exclusive with the gate below by
                    // construction (early return).
                    if awaitingZoomRecluster {
                        awaitingZoomRecluster = false
                        zoomReclusterWatchdog?.cancel()
                        zoomReclusterWatchdog = nil
                        currentSpan = newSpan
                        verifyZoomSplit()
                        return
                    }
                    let ratio = newSpan.latitudeDelta / max(currentSpan.latitudeDelta, 0.00001)
                    if ratio < zoomPerceptibleRatio || ratio > 1.4 {
                        currentSpan = newSpan
                        scheduleRecluster()
                    }
                }
                .onChange(of: selectedDive) { _, newValue in
                    if newValue != nil {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            clusterDives = nil
                        }
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                        .tint(.cyan)
                    MapCompass()
                    MapScaleView()
                }

                // Detail card when a dive is selected
                if let selected = selectedDive {
                    DiveMapCard(dive: selected, diveNumber: store.dives.firstIndex(where: { $0.persistentModelID == selected.persistentModelID }).map { store.dives.count - $0 } ?? 0, onClose: {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            selectedDive = nil
                        }
                    })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let list = clusterDives {
                    DiveClusterListCard(dives: list, onSelect: { dive in
                        withAnimation(.easeInOut(duration: 0.35)) {
                            clusterDives = nil
                            selectedDive = dive
                        }
                    }, onClose: {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            clusterDives = nil
                        }
                    })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif

            .onAppear {
                locationManager.requestWhenInUseAuthorization()
            }
            .sheet(isPresented: $showFilterSheet) {
                DiveFilterSheet(
                    availableYears: filterOptions.years,
                    availableGasTypes: filterOptions.gasTypes,
                    availableCountries: filterOptions.countries,
                    availableDiveTypes: filterOptions.diveTypes,
                    availableTags: filterOptions.tags,
                    availableMarineLife: filterOptions.marineLife,
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
                    sortOrder: .constant(.dateDesc)
                )
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .diverFilterReset(uniqueDivers: cachedUniqueDivers, selectedDiver: $selectedDiver)
            .background(mapObservers)
            .background(filterObservers)
            .toolbar {
                DiverFilterToolbar(uniqueDivers: cachedUniqueDivers, selectedDiver: $selectedDiver)
                ToolbarItem(placement: .principal) {
                    Picker("Coordinate Mode", selection: $coordinateMode) {
                        Text("Entry").tag(MapCoordinateMode.entry)
                        Text("Exit").tag(MapCoordinateMode.exit)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                ToolbarItem(placement: .primaryAction) {
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
                    .accessibilityLabel(activeFilterCount == 0
                        ? Text(verbatim: NSLocalizedString("Filter dives", bundle: .forAppLanguage(), comment: "Accessibility label for the filter button when no filters are active"))
                        : Text(verbatim: String(format: NSLocalizedString("%d active filters", bundle: .forAppLanguage(), comment: "Accessibility label for the filter button showing the number of active filters"), activeFilterCount))
                    )
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            cameraPosition = .automatic
                        } label: {
                            Label("Global View", systemImage: "globe")
                        }

                        Button {
                            cameraPosition = .region(MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                                span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)
                            ))
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }

                        Divider()

                        Section("Map Style") {
                            Button {
                                mapStyle = .standard(elevation: .realistic)
                            } label: {
                                Label("Standard Map", systemImage: "map")
                            }

                            Button {
                                mapStyle = .hybrid(elevation: .realistic)
                            } label: {
                                Label("Hybrid View", systemImage: "map.fill")
                            }

                            Button {
                                mapStyle = .imagery(elevation: .realistic)
                            } label: {
                                Label("Satellite View", systemImage: "globe.americas.fill")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.cyan)
                    }
                    .accessibilityLabel(Text("More"))
                }
            }
        }
    }
}

// MARK: - Dive Map Pin

struct DiveMapPin: View {
    let dive: Dive
    let isSelected: Bool

    // Diver initials when the dive has a named diver; nil for unnamed dives,
    // which fall back to the orange flag pin so "?" never appears on the map.
    private var diverInitials: String? {
        let trimmed = dive.diverName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : DiverFilter.initials(for: trimmed)
    }

    var body: some View {
        let initials = diverInitials
        let tint: Color = initials == nil ? .orange : .cyan
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: isSelected ? 44 : 32, height: isSelected ? 44 : 32)
                    .overlay(
                        Circle()
                            .stroke(.white, lineWidth: isSelected ? 3 : 2)
                    )
                    .shadow(radius: 5)

                if let initials {
                    Text(verbatim: initials)
                        .font(.system(size: isSelected ? 16 : 12, weight: .semibold))
                        .foregroundStyle(Color.black)
                } else {
                    Image(systemName: "flag")
                        .font(isSelected ? .title3 : .caption)
                        .foregroundStyle(.primary)
                }
            }
            // VStack siblings still paint in declaration order where they overlap (same
            // as a ZStack), so without this the triangle — declared second — would paint
            // over the circle's bottom edge in the `-2` seam below. Keeping the circle on
            // top lets its round edge cleanly cover the triangle's flat top corners.
            .zIndex(1)

            // Triangle pointer — apex at the bottom (flat edge at top, against the
            // circle) so the tip is a single precise point, matching anchor: .bottom.
            // The `-2` offset closes the seam against the circle above it. Shared shape
            // (see MapPointerPin.swift) so this geometry lives in exactly one place.
            PinTrianglePointer()
                .fill(tint)
                .frame(width: 20, height: 15)
                .offset(y: -2)
        }
        .animation(.spring(response: 0.3), value: isSelected)
    }
}

// MARK: - Dive Map Cluster Pin

struct DiveMapClusterPin: View {
    let count: Int
    // Cyan when every dive in the cluster belongs to one named diver, orange when the
    // cluster mixes divers (or none are named) — matches DiveMapPin's single-dive tint
    // convention. The badge always shows the count regardless of tint.
    var isSingleDiver: Bool = false

    var body: some View {
        let tint: Color = isSingleDiver ? .cyan : .orange
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Circle().stroke(.white, lineWidth: 2)
                    )
                    .shadow(radius: 5)

                // Black-on-cyan matches DiveMapPin's initials convention; white-on-orange
                // matches this pin's existing count convention.
                Text(verbatim: Double(count).localizedString(decimals: 0))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isSingleDiver ? Color.black : .white)
            }
            // VStack siblings still paint in declaration order where they overlap (same
            // as a ZStack), so without this the triangle — declared second — would paint
            // over the circle's bottom edge in the `-2` seam below. Keeping the circle on
            // top lets its round edge cleanly cover the triangle's flat top corners.
            .zIndex(1)

            // Triangle pointer — apex at the bottom (flat edge at top, against the
            // circle) so the tip is a single precise point, matching anchor: .bottom.
            // The `-2` offset closes the seam against the circle above it. Shared shape
            // (see MapPointerPin.swift) so this geometry lives in exactly one place.
            PinTrianglePointer()
                .fill(tint)
                .frame(width: 20, height: 15)
                .offset(y: -2)
        }
    }
}

// MARK: - Dive Cluster List Card

struct DiveClusterListCard: View {
    let dives: [Dive]
    let onSelect: (Dive) -> Void
    let onClose: () -> Void
    @Environment(\.locale) private var locale
    @State private var prefs = UserPreferences.shared

    /// Row leading icon: a cyan initials badge when this dive's diver is named
    /// (matching the map pins); otherwise the orange flag badge (unknown diver).
    @ViewBuilder
    private func rowIcon(for dive: Dive) -> some View {
        let name = dive.diverName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            Text(verbatim: DiverFilter.initials(for: name))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.cyan))
        } else {
            Image(systemName: "flag")
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.orange))
        }
    }

    /// Height that fits up to 3 rows exactly; beyond 3 dives the list scrolls.
    private var listScrollHeight: CGFloat {
        let rowHeight: CGFloat = 56
        let rowSpacing: CGFloat = 8
        let visibleRows = min(dives.count, 3)
        return CGFloat(visibleRows) * rowHeight + CGFloat(max(visibleRows - 1, 0)) * rowSpacing
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: String(format: NSLocalizedString("%@ dives at this location", bundle: .forAppLanguage(), comment: "Number of dives at a cluster location"), Double(dives.count).localizedString(decimals: 0)))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if dives.dropFirst().allSatisfy({ $0.siteName == dives.first?.siteName }),
                       let name = dives.first?.siteName, !name.isEmpty {
                        Text(verbatim: name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        // Top-trailing of the popup header: empty Spacer leading, 16 pt of card
                        // padding above and trailing, and 12 pt to the dive list below, so a
                        // symmetric 9 pt expansion stays clear of the list rows. 44 × 44 pt.
                        .tapTargetInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
                }
                .accessibilityLabel(Text("Close"))
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(dives.sorted(by: { $0.timestamp > $1.timestamp })) { dive in
                        Button {
                            onSelect(dive)
                        } label: {
                            HStack(spacing: 12) {
                                rowIcon(for: dive)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(formattedDate(dive.timestamp))
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 8) {
                                        Label(dive.displayMaxDepth.localizedString(decimals: 1) + prefs.depthUnit.symbol, systemImage: "arrow.down")
                                            .font(.caption2)
                                            .foregroundStyle(.cyan)
                                        Label(dive.shortFormattedDuration, systemImage: "clock")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.secondary.opacity(0.1))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: listScrollHeight)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)
                .shadow(radius: 10)
        )
        .padding()
    }
}

// MARK: - Dive Map Card

struct DiveMapCard: View {
    let dive: Dive
    let diveNumber: Int
    let onClose: () -> Void
    @Environment(\.locale) private var locale
    @State private var prefs = UserPreferences.shared

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var locationText: Text {
        var parts: [String] = []
        if !dive.location.isEmpty && dive.location != NSLocalizedString("Unknown", bundle: .forAppLanguage(), comment: "Default text for a location that is not known.") {
            parts.append(dive.location)
        }
        if let country = dive.siteCountry, !country.isEmpty {
            parts.append(country)
        }
        return parts.isEmpty ? Text("Unknown location") : Text(verbatim: parts.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: dive.siteName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    // Location + Country
                    HStack(spacing: 4) {
                        if dive.hasGPSCoordinates {
                            Image(systemName: "location.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Has GPS coordinates"))
                        }

                        locationText
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if !(dive.seenFish?.isEmpty ?? true) {
                    Image(systemName: "fish.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.teal)
                        .accessibilityLabel(Text("Has fish sightings"))
                }

                if !(dive.photosData?.isEmpty ?? true) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .accessibilityLabel(Text("Has photos"))
                }

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        // Top-trailing of the popup header. The fish/camera glyphs 8 pt to its
                        // leading are decorative, and there is 16 pt of card padding above and
                        // trailing plus 12 pt of non-interactive stats below. 44 × 44 pt.
                        .tapTargetInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
                }
                .accessibilityLabel(Text("Close"))
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(dive.displayMaxDepth.localizedString(decimals: 1) + prefs.depthUnit.symbol, systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                    Text("Max Depth")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Label(dive.shortFormattedDuration, systemImage: "clock.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("Duration")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Label(formattedDate(dive.timestamp), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Date")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink(destination: DiveDetailView(dive: dive, diveNumber: diveNumber)) {
                HStack {
                    Text("View Details")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(.white)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.cyan)
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)
                .shadow(radius: 10)
        )
        .padding()
    }
}

#Preview {
    DiveMapView()
        .modelContainer(for: Dive.self, inMemory: true)
}
