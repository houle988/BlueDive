import SwiftUI
import MapKit
import SwiftData
import CoreLocation

private enum MapCoordinateMode: CaseIterable {
    case entry, exit
}

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

    @State private var currentSpan: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)
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
                let minID = raw.memberIDs.min(by: { $0.uuidString < $1.uuidString })?.uuidString ?? ""
                return DiveCluster(
                    id: "\(minID)_\(raw.memberIDs.count)",
                    coordinate: CLLocationCoordinate2D(latitude: raw.centroidLat, longitude: raw.centroidLon),
                    dives: dives
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
            cachedClusters = rawResults.compactMap { raw in
                let dives = raw.memberIDs.compactMap { byID[$0] }
                guard !dives.isEmpty else { return nil }
                let minID = raw.memberIDs.min(by: { $0.uuidString < $1.uuidString })?.uuidString ?? ""
                return DiveCluster(
                    id: "\(minID)_\(raw.memberIDs.count)",
                    coordinate: CLLocationCoordinate2D(latitude: raw.centroidLat, longitude: raw.centroidLon),
                    dives: dives
                )
            }.sorted { $0.id < $1.id }
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
        let radiusLat = max(span.latitudeDelta, 0.00001) / 20.0
        let baseLonRadius = max(span.longitudeDelta, 0.00001) / 20.0
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

    private func handleClusterTap(_ cluster: DiveCluster) {
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

        // "Same spot" test in meters (robust at all latitudes).
        let corner1 = CLLocation(latitude: minLat, longitude: minLon)
        let corner2 = CLLocation(latitude: maxLat, longitude: maxLon)
        let spreadMeters = corner1.distance(from: corner2)
        let sameSpot = spreadMeters < 10 // meters
        // Also bail out of zooming once we're already very close in.
        let alreadyClose = currentSpan.latitudeDelta < 0.002
        if sameSpot || alreadyClose {
            withAnimation(.easeInOut(duration: 0.35)) {
                clusterDives = cluster.dives
            }
            return
        }

        // Zoom to the cluster's bounding box (with padding) so a single tap is
        // always effective, regardless of how far out we started.
        let centerLat = (minLat + maxLat) / 2.0
        let centerLon = (minLon + maxLon) / 2.0
        let latDelta = max((maxLat - minLat) * 2.5, 0.002)
        let lonDelta = max((maxLon - minLon) * 2.5, 0.002)
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
            ))
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $cameraPosition, selection: $selectedDive) {
                    ForEach(cachedClusters) { cluster in
                        if cluster.dives.count == 1, let dive = cluster.dives.first {
                            Annotation(
                                dive.siteName,
                                coordinate: cluster.coordinate
                            ) {
                                DiveMapPin(dive: dive, isSelected: selectedDive?.id == dive.id)
                            }
                            .tag(dive)
                        } else {
                            Annotation(
                                String(format: NSLocalizedString("%@ dives", bundle: .forAppLanguage(), comment: "Plural dive count in a cluster map annotation"), Double(cluster.dives.count).localizedString(decimals: 0)),
                                coordinate: cluster.coordinate
                            ) {
                                DiveMapClusterPin(count: cluster.dives.count)
                                    .onTapGesture {
                                        handleClusterTap(cluster)
                                    }
                                    .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("%@ dives at this location", bundle: .forAppLanguage(), comment: "Number of dives at a cluster location"), Double(cluster.dives.count).localizedString(decimals: 0))))
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                    }
                    UserAnnotation()
                }
                .mapStyle(mapStyle)
                .onMapCameraChange(frequency: .onEnd) { context in
                    // Only re-cluster when the user has actually zoomed. Panning
                    // (especially north/south) produces small Mercator-projection
                    // span drift that we want to ignore so clusters stay stable.
                    // Sub-threshold zooms naturally accumulate because the
                    // baseline only advances when we cross the threshold.
                    let newSpan = context.region.span
                    let ratio = newSpan.latitudeDelta / max(currentSpan.latitudeDelta, 0.00001)
                    if ratio < 0.7 || ratio > 1.4 {
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
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                .font(.title3)
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
                }
                ToolbarItem(placement: .confirmationAction) {
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
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.cyan)
                    }
                }
            }
        }
    }
}

// MARK: - Dive Map Pin

struct DiveMapPin: View {
    let dive: Dive
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.orange)
                    .frame(width: isSelected ? 44 : 32, height: isSelected ? 44 : 32)
                    .overlay(
                        Circle()
                            .stroke(.white, lineWidth: isSelected ? 3 : 2)
                    )
                    .shadow(radius: 5)

                Image(systemName: "flag.fill")
                    .font(isSelected ? .title3 : .caption)
                    .foregroundStyle(.primary)
            }

            // Triangle pointer
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 10, y: 15))
                path.addLine(to: CGPoint(x: -10, y: 15))
                path.closeSubpath()
            }
            .fill(Color.orange)
            .frame(width: 20, height: 15)
            .offset(y: -2)
        }
        .animation(.spring(response: 0.3), value: isSelected)
    }
}

// MARK: - Dive Map Cluster Pin

struct DiveMapClusterPin: View {
    let count: Int

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Circle().stroke(.white, lineWidth: 2)
                    )
                    .shadow(radius: 5)

                Text(verbatim: Double(count).localizedString(decimals: 0))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }

            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 10, y: 15))
                path.addLine(to: CGPoint(x: -10, y: 15))
                path.closeSubpath()
            }
            .fill(Color.orange)
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
                }
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(dives.sorted(by: { $0.timestamp > $1.timestamp })) { dive in
                        Button {
                            onSelect(dive)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "flag.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(Color.orange))

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
                }

                if !(dive.photosData?.isEmpty ?? true) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
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
