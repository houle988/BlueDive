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
    @State private var filterMinRating: Int = 0
    @State private var filterCountry: String? = nil
    @State private var filterDiveType: String? = nil
    @State private var filterTag: String? = nil
    @State private var filterDiverName: String? = nil
    @State private var filterMarineLife: String = ""
    @State private var sortOrder: ContentView.DiveSortOrder = .dateDesc
    
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
        if filterMinDepth > 0           { count += 1 }
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
            if let gas = filterGasType, dive.gasType != gas { return false }
            if filterMinDepth > 0, dive.displayMaxDepth < filterMinDepth { return false }
            if filterMinRating > 0, dive.rating < filterMinRating { return false }
            if let country = filterCountry {
                guard let diveCountry = dive.siteCountry, diveCountry == country else { return false }
            }
            if let diveType = filterDiveType {
                let allTypes = dive.diveTypes?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                if !allTypes.contains(diveType) { return false }
            }
            if let tag = filterTag {
                let diveTags = dive.tags?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                if !diveTags.contains(tag) { return false }
            }
            if let name = filterDiverName, dive.diverName != name { return false }
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
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $cameraPosition, selection: $selectedDive) {
                    ForEach(divesWithCoordinates, id: \.dive.id) { item in
                        Annotation(
                            item.dive.siteName,
                            coordinate: item.coordinate
                        ) {
                            DiveMapPin(dive: item.dive, isSelected: selectedDive?.id == item.dive.id)
                        }
                        .tag(item.dive)
                    }
                    UserAnnotation()
                }
                .mapStyle(mapStyle)
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                
                // Detail card when a dive is selected
                if let selected = selectedDive {
                    DiveMapCard(dive: selected, onClose: {
                        selectedDive = nil
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
                    filterMinRating: $filterMinRating,
                    filterCountry: $filterCountry,
                    filterDiveType: $filterDiveType,
                    filterTag: $filterTag,
                    filterDiverName: $filterDiverName,
                    filterMarineLife: $filterMarineLife,
                    sortOrder: $sortOrder
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
    
    private var pinColor: Color {
        return .orange
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(pinColor)
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
            .fill(pinColor)
            .frame(width: 20, height: 15)
            .offset(y: -2)
        }
        .animation(.spring(response: 0.3), value: isSelected)
    }
}

// MARK: - Dive Map Card

struct DiveMapCard: View {
    let dive: Dive
    let onClose: () -> Void
    @Environment(\.modelContext) private var modelContext
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
        if !dive.location.isEmpty && dive.location != "Inconnu" && dive.location != String(localized: "Unknown") {
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
                    Text(dive.siteName)
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
