import SwiftUI
import MapKit

// MARK: - Site Details Tab

extension DiveDetailView {

    var siteDetailsTabContent: some View {
        VStack(spacing: 20) {
            siteDetailsInfoCard
        }
    }

    var siteDetailsInfoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("Site Details")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Spacer()
            }

            // Dive Site
            conditionRow(icon: "location.fill", color: .cyan, label: "Dive Site",
                        value: dive.siteName.isEmpty ? "—" : dive.siteName)

            Divider().background(.primary.opacity(0.2))

            // Country with flag
            let countryInfo = CountryLookup.resolve(dive.siteCountry)
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(countryInfo.color.opacity(0.2))
                        .frame(width: 36, height: 36)
                    Text(countryInfo.flag)
                        .font(.system(size: 20))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Country")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(dive.siteCountry?.isEmpty == false ? dive.siteCountry! : "—")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(dive.siteCountry?.isEmpty == false ? .primary : .secondary)
                }
                Spacer()
            }

            Divider().background(.primary.opacity(0.2))

            // Location
            conditionRow(icon: "mappin.and.ellipse", color: .orange, label: "Location",
                        value: dive.location.isEmpty ? "—" : dive.location)

            Divider().background(.primary.opacity(0.2))

            // Difficulty
            difficultyDisplayRow

            Divider().background(.primary.opacity(0.2))

            // Water Type
            conditionRow(icon: "drop.fill", color: .blue, label: "Water Type",
                        value: localizedWaterType(dive.siteWaterType))

            Divider().background(.primary.opacity(0.2))

            // Body of Water
            conditionRow(icon: "water.waves", color: .teal, label: "Body of Water",
                        value: dive.siteBodyOfWater?.isEmpty == false ? dive.siteBodyOfWater! : "—")

            Divider().background(.primary.opacity(0.2))

            // GPS Coordinates (Entry)
            if let lat = dive.siteLatitude, let lon = dive.siteLongitude {
                conditionRow(icon: "location.circle.fill", color: .green, label: "Coordinates (entry)",
                            value: String(format: "%.6f, %.6f", lat, lon))
            } else {
                conditionRow(icon: "location.circle.fill", color: .green, label: "Coordinates (entry)",
                            value: "—")
            }

            Divider().background(.primary.opacity(0.2))

            // GPS Coordinates (Exit)
            if let exitLat = dive.exitLatitude, let exitLon = dive.exitLongitude {
                conditionRow(icon: "location.circle", color: .green, label: "Coordinates (exit)",
                            value: String(format: "%.6f, %.6f", exitLat, exitLon))
            } else {
                conditionRow(icon: "location.circle", color: .green, label: "Coordinates (exit)",
                            value: "—")
            }

            Divider().background(.primary.opacity(0.2))

            // Altitude
            if let alt = dive.displaySiteAltitude {
                let depthUnit = prefs.depthUnit.symbol
                conditionRow(icon: "mountain.2.fill", color: .brown, label: "Altitude",
                            value: alt.localizedString(decimals: 0) + " \(depthUnit)")
            } else {
                conditionRow(icon: "mountain.2.fill", color: .brown, label: "Altitude",
                            value: "—")
            }

            // Map view — tap to open a larger, zoomable map.
            if let lat = dive.siteLatitude, let lon = dive.siteLongitude {
                Divider().background(.primary.opacity(0.2))

                siteMap(entryLat: lat, entryLon: lon,
                        exitLat: dive.exitLatitude, exitLon: dive.exitLongitude)
                    .frame(height: 200)
                    // Keep the preview itself non-interactive so the tap gesture
                    // below (not the map's own pan/zoom) receives the touch.
                    .allowsHitTesting(false)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(8)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { showFullScreenSiteMap = true }
                    .accessibilityElement()
                    .accessibilityLabel(Text("View larger map"))
                    .accessibilityAddTraits(.isButton)
                    // onTapGesture isn't reliably fired by VoiceOver's activate
                    // gesture; this makes double-tap open the large map.
                    .accessibilityAction { showFullScreenSiteMap = true }
            }
        }
        .padding()
        .detailCardBackground()
        .padding(.horizontal)
        .sheet(isPresented: $showFullScreenSiteMap) {
            if let lat = dive.siteLatitude, let lon = dive.siteLongitude {
                SiteMapFullScreenView(
                    entryLat: lat, entryLon: lon,
                    exitLat: dive.exitLatitude, exitLon: dive.exitLongitude,
                    siteName: dive.siteName
                )
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private func siteMap(entryLat: Double, entryLon: Double, exitLat: Double?, exitLon: Double?) -> some View {
        let entryCoord = CLLocationCoordinate2D(latitude: entryLat, longitude: entryLon)

        if let eLat = exitLat, let eLon = exitLon {
            let exitCoord = CLLocationCoordinate2D(latitude: eLat, longitude: eLon)
            let center = CLLocationCoordinate2D(
                latitude: (entryLat + eLat) / 2,
                longitude: (entryLon + eLon) / 2
            )
            let span = MKCoordinateSpan(
                latitudeDelta: max(abs(entryLat - eLat) * 1.5, 0.005),
                longitudeDelta: max(abs(entryLon - eLon) * 1.5, 0.005)
            )
            Map(initialPosition: .region(MKCoordinateRegion(center: center, span: span))) {
                Annotation(coordinate: entryCoord, anchor: .bottom) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                } label: {
                    if dive.siteName.isEmpty {
                        Text("Entry")
                    } else {
                        Text(verbatim: dive.siteName)
                    }
                }
                Annotation(coordinate: exitCoord, anchor: .bottom) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                } label: {
                    Text("Exit")
                }
            }
        } else {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: entryCoord,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))) {
                Annotation(coordinate: entryCoord, anchor: .bottom) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                } label: {
                    if dive.siteName.isEmpty {
                        Text("Dive Site")
                    } else {
                        Text(verbatim: dive.siteName)
                    }
                }
            }
        }
    }

    var difficultyDisplayRow: some View {
        let scale = EditSiteDetailsView.difficultyScale
        let level: Int = {
            if let raw = dive.siteDifficulty, let n = Int(raw), (1...10).contains(n) { return n }
            return scale.first(where: { $0.label == dive.siteDifficulty })?.level ?? 0
        }()
        let label = scale.first(where: { $0.level == level })?.label

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: "star.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.purple)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Difficulty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if level > 0, let label {
                    Text(LocalizedStringKey(label))
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                } else if let raw = dive.siteDifficulty, !raw.isEmpty {
                    // Legacy text value
                    Text(raw)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                } else {
                    Text("—")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Full-Screen Site Map

/// An interactive, zoomable map of a single dive site, presented as a sheet from
/// the Site Details preview. Takes plain coordinates so it needs no `Dive` or
/// `DiveStore` access — it is a pure read of the values passed in.
struct SiteMapFullScreenView: View {
    let entryLat: Double
    let entryLon: Double
    let exitLat: Double?
    let exitLon: Double?
    let siteName: String

    @Environment(\.dismiss) private var dismiss
    // Standard by default so the large map matches the Site Details preview. The
    // user can switch to hybrid/satellite via the style menu.
    @State private var mapStyle: MapStyle = .standard(elevation: .realistic)

    // The framed region for this site, computed once from the coordinates.
    private var targetRegion: MKCoordinateRegion {
        if let eLat = exitLat, let eLon = exitLon {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (entryLat + eLat) / 2,
                                               longitude: (entryLon + eLon) / 2),
                span: MKCoordinateSpan(
                    latitudeDelta: max(abs(entryLat - eLat) * 1.5, 0.005),
                    longitudeDelta: max(abs(entryLon - eLon) * 1.5, 0.005)
                )
            )
        } else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: entryLat, longitude: entryLon),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        }
    }

    var body: some View {
        NavigationStack {
            // Uncontrolled initial camera (like the Site Details preview) so the
            // annotations render immediately. A bound `position` with an initial
            // region leaves MapKit not laying out pins until the first camera
            // change (they only appear after a pan); `initialPosition` avoids that.
            Map(initialPosition: .region(targetRegion)) {
                let entryCoord = CLLocationCoordinate2D(latitude: entryLat, longitude: entryLon)
                if let eLat = exitLat, let eLon = exitLon {
                    Annotation(coordinate: entryCoord, anchor: .bottom) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                    } label: {
                        if siteName.isEmpty {
                            Text("Entry")
                        } else {
                            Text(verbatim: siteName)
                        }
                    }
                    Annotation(coordinate: CLLocationCoordinate2D(latitude: eLat, longitude: eLon), anchor: .bottom) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .orange)
                    } label: {
                        Text("Exit")
                    }
                } else {
                    Annotation(coordinate: entryCoord, anchor: .bottom) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                    } label: {
                        if siteName.isEmpty {
                            Text("Dive Site")
                        } else {
                            Text(verbatim: siteName)
                        }
                    }
                }
            }
            .mapStyle(mapStyle)
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Site Map")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
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
