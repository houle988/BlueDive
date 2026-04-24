import SwiftUI
import MapKit
import SwiftData
import CoreLocation

struct DiveMapView: View {
    @Query(sort: \Dive.timestamp, order: .reverse) private var dives: [Dive]
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedDive: Dive?
    @State private var mapStyle: MapStyle = .standard(elevation: .realistic)
    @State private var locationManager = CLLocationManager()

    // MARK: - Filter State
    @State private var showFilterSheet = false
    @State private var filterYear: Int? = nil
    @State private var filterGasType: String? = nil
    @State private var filterMinDepth: Double = 0
    @State private var filterMaxDepth: Double = 0
    @State private var filterMinRating: Int = 0
    @State private var filterCountry: String? = nil
    @State private var filterDiveType: String? = nil
    @State private var filterTag: String? = nil
    @State private var filterDiverName: String? = nil
    @State private var filterMarineLife: String = ""
    
    private func coordinate(for dive: Dive) -> CLLocationCoordinate2D? {
        if let lat = dive.siteLatitude, let lon = dive.siteLongitude,
           !(lat == 0 && lon == 0),
           CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }
    
    // MARK: - Available Filter Options (only from dives with coordinates)

    private var geolocatedDives: [Dive] {
        dives.filter { coordinate(for: $0) != nil }
    }

    private var availableYears: [Int] {
        let years = geolocatedDives.compactMap { Calendar.current.dateComponents([.year], from: $0.timestamp).year }
        return Array(Set(years)).sorted(by: >)
    }

    private var availableGasTypes: [String] {
        let types = geolocatedDives.map { $0.gasType }
        return Array(Set(types)).sorted()
    }

    private var availableCountries: [String] {
        let countries = geolocatedDives.compactMap { $0.siteCountry }.filter { !$0.isEmpty }
        return Array(Set(countries)).sorted()
    }

    private var availableDiveTypes: [String] {
        var types = Set<String>()
        for dive in geolocatedDives {
            dive.diveTypes?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .forEach { types.insert($0) }
        }
        return types.sorted()
    }

    private var availableTags: [String] {
        var tags = Set<String>()
        for dive in geolocatedDives {
            dive.tags?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .forEach { tags.insert($0) }
        }
        return tags.sorted()
    }

    private var availableDiverNames: [String] {
        let names = geolocatedDives.map { $0.diverName }.filter { !$0.isEmpty }
        return Array(Set(names)).sorted()
    }

    private var availableMarineLife: [String] {
        var species = Set<String>()
        for dive in geolocatedDives {
            dive.seenFish?.forEach { sight in
                let name = sight.name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { species.insert(name) }
            }
        }
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
        if filterDiverName != nil       { count += 1 }
        if !filterMarineLife.isEmpty    { count += 1 }
        return count
    }
    
    private var filteredDives: [Dive] {
        dives.filter { dive in
            if let year = filterYear {
                let diveYear = Calendar.current.component(.year, from: dive.timestamp)
                if diveYear != year { return false }
            }
            if let gas = filterGasType {
                if gas.isEmpty {
                    if !dive.gasType.isEmpty { return false }
                } else {
                    if dive.gasType != gas { return false }
                }
            }
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
            if filterMinRating > 0, dive.rating < filterMinRating { return false }
            if let country = filterCountry {
                if country.isEmpty {
                    guard dive.siteCountry == nil || dive.siteCountry!.isEmpty else { return false }
                } else {
                    guard let diveCountry = dive.siteCountry, diveCountry == country else { return false }
                }
            }
            if let diveType = filterDiveType {
                if diveType.isEmpty {
                    let trimmed = dive.diveTypes?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !trimmed.isEmpty { return false }
                } else {
                    let allTypes = dive.diveTypes?
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                    if !allTypes.contains(diveType) { return false }
                }
            }
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
            if let name = filterDiverName {
                if name.isEmpty {
                    if !dive.diverName.isEmpty { return false }
                } else {
                    if dive.diverName != name { return false }
                }
            }
            if !filterMarineLife.isEmpty {
                let match = dive.seenFish?.contains { $0.name.localizedCaseInsensitiveContains(filterMarineLife) } ?? false
                if !match { return false }
            }
            return true
        }
    }

    private var divesWithCoordinates: [(dive: Dive, coordinate: CLLocationCoordinate2D)] {
        filteredDives.compactMap { dive in
            if let coord = coordinate(for: dive) {
                return (dive, coord)
            }
            return nil
        }
    }

    // MARK: - Clustering

    @State private var currentSpan: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)
    @State private var clusterDives: [Dive]? = nil

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

    private var clusters: [DiveCluster] {
        // Overlap radius scales with visible span so the clustering threshold
        // matches the pin's screen-space footprint (~1/20th of the visible span).
        let radiusLat = max(currentSpan.latitudeDelta, 0.00001) / 20.0
        let baseLonRadius = max(currentSpan.longitudeDelta, 0.00001) / 20.0

        // Greedy distance-based clustering. Unlike a fixed grid, this has no
        // cell-edge artifact: two visually overlapping pins always merge.
        // Centroid is recomputed as members are added to keep assignments stable.
        struct WorkingCluster {
            var sumLat: Double
            var sumLon: Double
            var dives: [Dive]
            var coords: [CLLocationCoordinate2D]
            var centroid: CLLocationCoordinate2D {
                let n = Double(dives.count)
                return CLLocationCoordinate2D(latitude: sumLat / n, longitude: sumLon / n)
            }
        }

        var working: [WorkingCluster] = []
        // Process in deterministic order so cluster identity is stable across
        // recomputes (filteredDives is already sorted by timestamp desc).
        for item in divesWithCoordinates {
            let lat = item.coordinate.latitude
            let lon = normalizedLongitude(item.coordinate.longitude)
            // Compensate longitude radius by cos(latitude) so the cluster
            // threshold is roughly isotropic in on-screen distance at any latitude.
            let latCos = max(cos(lat * .pi / 180.0), 0.01)
            let radiusLon = baseLonRadius / latCos
            var merged = false
            for i in working.indices {
                let c = working[i].centroid
                if abs(lat - c.latitude) <= radiusLat && abs(lon - c.longitude) <= radiusLon {
                    working[i].sumLat += lat
                    working[i].sumLon += lon
                    working[i].dives.append(item.dive)
                    working[i].coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    merged = true
                    break
                }
            }
            if !merged {
                working.append(WorkingCluster(
                    sumLat: lat, sumLon: lon,
                    dives: [item.dive],
                    coords: [CLLocationCoordinate2D(latitude: lat, longitude: lon)]
                ))
            }
        }
        return working.map { entry -> DiveCluster in
            // Stable id = sorted member ids, so SwiftUI keeps the same annotation
            // identity across re-renders with the same membership.
            let ids = entry.dives.map { $0.id.uuidString }.sorted().joined(separator: "_")
            return DiveCluster(
                id: ids,
                coordinate: entry.centroid,
                dives: entry.dives
            )
        }
        // Deterministic order (independent of dictionary iteration).
        .sorted { $0.id < $1.id }
    }

    private func handleClusterTap(_ cluster: DiveCluster) {
        let lats = cluster.dives.compactMap { $0.siteLatitude }
        let lons = cluster.dives.compactMap { $0.siteLongitude }.map { normalizedLongitude($0) }
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
                    ForEach(clusters) { cluster in
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
                                "\(cluster.dives.count) dives",
                                coordinate: cluster.coordinate
                            ) {
                                DiveMapClusterPin(count: cluster.dives.count)
                                    .onTapGesture {
                                        handleClusterTap(cluster)
                                    }
                                    .accessibilityLabel(Text("\(cluster.dives.count) dives at this location"))
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
                    DiveMapCard(dive: selected, onClose: {
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
                    availableYears: availableYears,
                    availableGasTypes: availableGasTypes,
                    availableCountries: availableCountries,
                    availableDiveTypes: availableDiveTypes,
                    availableTags: availableTags,
                    availableDiverNames: availableDiverNames,
                    availableMarineLife: availableMarineLife,
                    showSort: false,
                    filterYear: $filterYear,
                    filterGasType: $filterGasType,
                    filterMinDepth: $filterMinDepth,
                    filterMaxDepth: $filterMaxDepth,
                    filterMinRating: $filterMinRating,
                    filterCountry: $filterCountry,
                    filterDiveType: $filterDiveType,
                    filterTag: $filterTag,
                    filterDiverName: $filterDiverName,
                    filterMarineLife: $filterMarineLife,
                    sortOrder: .constant(.dateDesc)
                )
                #if os(iOS)
                .presentationDetents([.large])
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showFilterSheet = true }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                .foregroundStyle(activeFilterCount > 0 ? .orange : .cyan)
                            
                            if activeFilterCount > 0 {
                                Text("\(activeFilterCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 16, height: 16)
                                    .background(Circle().fill(.red))
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
                        Image(systemName: "ellipsis.circle")
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

                Text(verbatim: "\(count)")
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
                    Text(verbatim: String(format: NSLocalizedString("%lld dives at this location", bundle: .forAppLanguage(), comment: "Number of dives at a cluster location"), dives.count))
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
                                        Label(prefs.depthUnit.formatted(dive.maxDepth), systemImage: "arrow.down")
                                            .font(.caption2)
                                            .foregroundStyle(.cyan)
                                        Label(dive.formattedDuration, systemImage: "clock")
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
                        Image(systemName: "location.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        
                        locationText
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
            
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(prefs.depthUnit.formatted(dive.maxDepth), systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                    Text("Max Depth")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                    .frame(height: 30)
                
                VStack(alignment: .leading, spacing: 4) {
                    Label(dive.formattedDuration, systemImage: "clock.fill")
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
            
            NavigationLink(destination: DiveDetailView(dive: dive)) {
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
