import SwiftUI
import MapKit

// MARK: - Site Details Tab

extension DiveDetailView {

    // Mirrors `Dive.hasGPSCoordinates`'s definition of a valid pair (both
    // components present and not the (0, 0) sentinel) so the map's per-pin
    // branches never see a coordinate the gate itself would have rejected.
    private func validGPSCoordinate(lat: Double?, lon: Double?) -> (lat: Double, lon: Double)? {
        guard let lat, let lon, !(lat == 0 && lon == 0) else { return nil }
        return (lat, lon)
    }

    var siteDetailsTabContent: some View {
        VStack(spacing: 20) {
            siteDetailsInfoCard
        }
    }

    var siteDetailsInfoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("Site Details")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Spacer()
            }

            // Dive Site
            ConditionRow(icon: "location", color: .cyan, label: "Dive Site",
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
                        .accessibilityHidden(true)
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
            .accessibilityElement(children: .combine)

            Divider().background(.primary.opacity(0.2))

            // Location
            ConditionRow(icon: "mappin.and.ellipse", color: .orange, label: "Location",
                        value: dive.location.isEmpty ? "—" : dive.location)

            Divider().background(.primary.opacity(0.2))

            // Difficulty
            difficultyDisplayRow

            Divider().background(.primary.opacity(0.2))

            // Water Type
            ConditionRow(icon: "drop", color: .blue, label: "Water Type",
                        value: localizedWaterType(dive.siteWaterType))

            Divider().background(.primary.opacity(0.2))

            // Body of Water
            ConditionRow(icon: "water.waves", color: .teal, label: "Body of Water",
                        value: dive.siteBodyOfWater?.isEmpty == false ? dive.siteBodyOfWater! : "—")

            Divider().background(.primary.opacity(0.2))

            // GPS Coordinates — when entry and exit are the exact same point, both
            // rows use the combined up/down purple marker, mirroring the single
            // combined pin shown on the map.
            let coordsIdentical: Bool = {
                guard let lat = dive.siteLatitude, let lon = dive.siteLongitude,
                      let eLat = dive.exitLatitude, let eLon = dive.exitLongitude else { return false }
                return lat == eLat && lon == eLon
            }()
            let entryIcon = coordsIdentical ? "arrow.up.arrow.down.circle" : "arrow.down.circle"
            let entryColor: Color = coordsIdentical ? .purple : .green
            let exitIcon = coordsIdentical ? "arrow.up.arrow.down.circle" : "arrow.up.circle"
            let exitColor: Color = coordsIdentical ? .purple : .orange

            // GPS Coordinates (Entry)
            if let lat = dive.siteLatitude, let lon = dive.siteLongitude {
                ConditionRow(icon: entryIcon, color: entryColor, label: "Coordinates (entry)",
                            value: String(format: "%.6f, %.6f", lat, lon))
            } else {
                ConditionRow(icon: entryIcon, color: entryColor, label: "Coordinates (entry)",
                            value: "—")
            }

            Divider().background(.primary.opacity(0.2))

            // GPS Coordinates (Exit)
            if let exitLat = dive.exitLatitude, let exitLon = dive.exitLongitude {
                ConditionRow(icon: exitIcon, color: exitColor, label: "Coordinates (exit)",
                            value: String(format: "%.6f, %.6f", exitLat, exitLon))
            } else {
                ConditionRow(icon: exitIcon, color: exitColor, label: "Coordinates (exit)",
                            value: "—")
            }

            Divider().background(.primary.opacity(0.2))

            // Altitude
            if let alt = dive.displaySiteAltitude {
                let depthUnit = prefs.depthUnit.symbol
                ConditionRow(icon: "mountain.2", color: .brown, label: "Altitude",
                            value: alt.localizedString(decimals: 0) + " \(depthUnit)")
            } else {
                ConditionRow(icon: "mountain.2", color: .brown, label: "Altitude",
                            value: "—")
            }

            // Map view — tap to open a larger, zoomable map.
            if dive.hasGPSCoordinates {
                Divider().background(.primary.opacity(0.2))

                let entry = validGPSCoordinate(lat: dive.siteLatitude, lon: dive.siteLongitude)
                let exit = validGPSCoordinate(lat: dive.exitLatitude, lon: dive.exitLongitude)
                siteMap(entryLat: entry?.lat, entryLon: entry?.lon,
                        exitLat: exit?.lat, exitLon: exit?.lon)
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
            if dive.hasGPSCoordinates {
                let entry = validGPSCoordinate(lat: dive.siteLatitude, lon: dive.siteLongitude)
                let exit = validGPSCoordinate(lat: dive.exitLatitude, lon: dive.exitLongitude)
                SiteMapFullScreenView(
                    entryLat: entry?.lat, entryLon: entry?.lon,
                    exitLat: exit?.lat, exitLon: exit?.lon,
                    siteName: dive.siteName
                )
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private func siteMap(entryLat: Double?, entryLon: Double?, exitLat: Double?, exitLon: Double?) -> some View {
        if let entryLat, let entryLon, let eLat = exitLat, let eLon = exitLon {
            let entryCoord = CLLocationCoordinate2D(latitude: entryLat, longitude: entryLon)
            let exitCoord = CLLocationCoordinate2D(latitude: eLat, longitude: eLon)
            let center = CLLocationCoordinate2D(
                latitude: (entryLat + eLat) / 2,
                longitude: (entryLon + eLon) / 2
            )
            let span = MKCoordinateSpan(
                latitudeDelta: max(abs(entryLat - eLat) * 1.5, 0.005),
                longitudeDelta: max(abs(entryLon - eLon) * 1.5, 0.005)
            )
            // `SiteEntryExitMap` owns the identical / overlapping / separate pin cases —
            // see its documentation for why overlapping pins must share one annotation.
            SiteEntryExitMap(
                entryCoord: entryCoord,
                exitCoord: exitCoord,
                region: MKCoordinateRegion(center: center, span: span),
                pinDiameter: 26
            )
        } else if let entryLat, let entryLon {
            // Entry only — same green as the combined-map entry pin.
            let entryCoord = CLLocationCoordinate2D(latitude: entryLat, longitude: entryLon)
            Map(initialPosition: .region(MKCoordinateRegion(
                center: entryCoord,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))) {
                Annotation(coordinate: entryCoord, anchor: .bottom) {
                    MapPointerPin(systemImage: "arrow.down", tint: .green, diameter: 26)
                } label: {
                    if dive.siteName.isEmpty {
                        Text("Entry")
                    } else {
                        Text(verbatim: dive.siteName)
                    }
                }
            }
        } else if let eLat = exitLat, let eLon = exitLon {
            // Exit only — same orange as the combined-map exit pin.
            let exitCoord = CLLocationCoordinate2D(latitude: eLat, longitude: eLon)
            Map(initialPosition: .region(MKCoordinateRegion(
                center: exitCoord,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))) {
                Annotation(coordinate: exitCoord, anchor: .bottom) {
                    MapPointerPin(systemImage: "arrow.up", tint: .orange, diameter: 26)
                } label: {
                    if dive.siteName.isEmpty {
                        Text("Exit")
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
                Image(systemName: "star")
                    .font(.system(size: 15))
                    .foregroundStyle(.purple)
                    // Purely decorative: without this, VoiceOver announces the SF
                    // Symbol's own system description ("star" reads as "Add to
                    // Favourites") before the real content below.
                    .accessibilityHidden(true)
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
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Entry / Exit Site Map

/// The Site Details map for a dive that has **both** an entry and an exit coordinate,
/// shared by the compact preview and the full-screen sheet so the two stay in step.
///
/// This view exists because the z-order of two overlapping pins is MapKit's decision,
/// not SwiftUI's. `Annotation` conforms to `MapContent`, not `View`, so `.zIndex()`
/// cannot be applied to it (it is a compile error), and the whole public `MapContent`
/// modifier surface — `tint`, `tag`, `foregroundStyle`, `stroke`, `strokeStyle`,
/// `annotationTitles`, `annotationSubtitles`, `mapOverlayLevel`,
/// `mapItemDetailSelectionAccessory` — exposes no equivalent of
/// `MKAnnotationView.zPriority` / `displayPriority`. MapKit orders overlapping
/// annotation views itself, drawing the southernmost in front, so the order the
/// annotations are declared in the content builder has **no** effect (verified on
/// device: swapping the two `Annotation` calls changed nothing).
///
/// So when the two pins are close enough to overlap, both are drawn from a *single*
/// `Annotation`. Inside one annotation's content view the stacking is a plain `ZStack`,
/// which is ours to control: the orange exit pin goes in first (behind), shifted by the
/// projected screen-space distance between the two coordinates so it still marks its own
/// position, and the green entry pin is drawn last (in front) and undisplaced. Once the
/// pins are far enough apart to read as two separate markers they go back to being two
/// independent annotations, each with its own anchor and its own label.
struct SiteEntryExitMap: View {
    let entryCoord: CLLocationCoordinate2D
    let exitCoord: CLLocationCoordinate2D
    /// Region the map opens on, supplied by the caller so the compact preview and the
    /// full-screen sheet keep framing the site identically.
    let region: MKCoordinateRegion
    /// `MapPointerPin` circle diameter — 26 on the compact preview, 32 full screen.
    let pinDiameter: CGFloat

    /// The map's laid-out size in points. `.zero` until the first layout pass, which is
    /// why `mergedExitOffset` returns `nil` (two plain annotations) until it is known.
    @State private var mapSize: CGSize = .zero
    /// The map rect actually on screen, tracked continuously so both the overlap test
    /// and the exit pin's offset stay correct while the user zooms the full-screen map.
    @State private var visibleRect: MKMapRect?

    /// Centre-to-centre screen distance, in points, below which the two pins are treated
    /// as overlapping and merged into one annotation. A pin circle is `pinDiameter`
    /// across, so anything closer than about one pin width hides part of the pin behind.
    private var overlapThreshold: CGFloat { pinDiameter + 12 }

    private var coordinatesIdentical: Bool {
        entryCoord.latitude == exitCoord.latitude && entryCoord.longitude == exitCoord.longitude
    }

    /// Screen-space vector from the entry pin to the exit pin, in points — or `nil` when
    /// the pins are identical, the map has not been laid out yet, or the two are far
    /// enough apart that they should stay two independent annotations.
    private var mergedExitOffset: CGSize? {
        guard !coordinatesIdentical, mapSize.width > 0, mapSize.height > 0 else { return nil }
        // Until the first camera callback arrives, project against the region we asked
        // for, so the merged pins are already correct on the very first frame.
        let rect = visibleRect ?? Self.mapRect(for: region)
        guard rect.width > 0, rect.height > 0 else { return nil }
        // Points per `MKMapPoint`. `min` mirrors how MapKit fits a requested region into
        // a view of a different aspect ratio; for a rect read back from the camera the
        // two ratios are already equal, so it is exact there too.
        let scale = min(mapSize.width / rect.width, mapSize.height / rect.height)
        let entryPoint = MKMapPoint(entryCoord)
        let exitPoint = MKMapPoint(exitCoord)
        let offset = CGSize(width: (exitPoint.x - entryPoint.x) * scale,
                            height: (exitPoint.y - entryPoint.y) * scale)
        guard hypot(offset.width, offset.height) < overlapThreshold else { return nil }
        return offset
    }

    /// `MKCoordinateRegion` has no `MKMapRect` bridge, so project its north-west and
    /// south-east corners instead.
    private static func mapRect(for region: MKCoordinateRegion) -> MKMapRect {
        let northWest = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2))
        let southEast = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2))
        return MKMapRect(x: min(northWest.x, southEast.x),
                         y: min(northWest.y, southEast.y),
                         width: abs(southEast.x - northWest.x),
                         height: abs(southEast.y - northWest.y))
    }

    private var entryPin: MapPointerPin {
        MapPointerPin(systemImage: "arrow.down", tint: .green, diameter: pinDiameter)
    }

    private var exitPin: MapPointerPin {
        MapPointerPin(systemImage: "arrow.up", tint: .orange, diameter: pinDiameter)
    }

    var body: some View {
        Map(initialPosition: .region(region)) {
            if coordinatesIdentical {
                // Exactly the same point: one combined pin rather than two markers
                // stacked perfectly on top of each other.
                Annotation(coordinate: entryCoord, anchor: .bottom) {
                    MapPointerPin(systemImage: "arrow.up.arrow.down", tint: .purple,
                                  diameter: pinDiameter)
                } label: {
                    Text("Entry & exit")
                }
            } else if let mergedExitOffset {
                // Close enough to overlap: one annotation, two pins, and a ZStack whose
                // order we control — exit behind at its own projected position, entry
                // in front.
                Annotation(coordinate: entryCoord, anchor: .bottom) {
                    ZStack(alignment: .bottom) {
                        exitPin
                            .offset(x: mergedExitOffset.width, y: mergedExitOffset.height)
                        entryPin
                    }
                } label: {
                    Text("Entry & exit")
                }
            } else {
                // Far enough apart to read as two pins: keep them independent so each
                // one keeps its own anchor and its own accurate label.
                Annotation(coordinate: exitCoord, anchor: .bottom) {
                    exitPin
                } label: {
                    Text("Exit")
                }
                Annotation(coordinate: entryCoord, anchor: .bottom) {
                    entryPin
                } label: {
                    Text("Entry")
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            mapSize = newSize
        }
        .onMapCameraChange(frequency: .continuous) { context in
            visibleRect = context.rect
        }
    }
}

// MARK: - Full-Screen Site Map

/// An interactive, zoomable map of a single dive site, presented as a sheet from
/// the Site Details preview. Takes plain coordinates so it needs no `Dive` or
/// `DiveStore` access — it is a pure read of the values passed in.
struct SiteMapFullScreenView: View {
    let entryLat: Double?
    let entryLon: Double?
    let exitLat: Double?
    let exitLon: Double?
    let siteName: String

    @Environment(\.dismiss) private var dismiss
    // Standard by default so the large map matches the Site Details preview. The
    // user can switch to hybrid/satellite via the style menu.
    @State private var mapStyle: MapStyle = .standard(elevation: .realistic)

    // The framed region for this site, computed once from the coordinates.
    private var targetRegion: MKCoordinateRegion {
        if let entryLat, let entryLon, let eLat = exitLat, let eLon = exitLon {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (entryLat + eLat) / 2,
                                               longitude: (entryLon + eLon) / 2),
                span: MKCoordinateSpan(
                    latitudeDelta: max(abs(entryLat - eLat) * 1.5, 0.005),
                    longitudeDelta: max(abs(entryLon - eLon) * 1.5, 0.005)
                )
            )
        } else if let entryLat, let entryLon {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: entryLat, longitude: entryLon),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        } else if let eLat = exitLat, let eLon = exitLon {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: eLat, longitude: eLon),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        } else {
            // Unreachable: the sole caller only presents this view when
            // `dive.hasGPSCoordinates` is true, and passes entry/exit through
            // the same (0, 0)-excluding check, so at least one pair is always
            // present here. Required only for exhaustiveness.
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        }
    }

    /// The map itself. `mapStyle` / `mapControls` are `View` modifiers that reach any
    /// `Map` below them through the environment, so `body` can apply them to this
    /// property whether the map comes from `SiteEntryExitMap` or is built inline here.
    @ViewBuilder
    private var siteMapContent: some View {
        if let entryLat, let entryLon, let eLat = exitLat, let eLon = exitLon {
            // `SiteEntryExitMap` owns the identical / overlapping / separate pin cases —
            // see its documentation for why overlapping pins must share one annotation.
            SiteEntryExitMap(
                entryCoord: CLLocationCoordinate2D(latitude: entryLat, longitude: entryLon),
                exitCoord: CLLocationCoordinate2D(latitude: eLat, longitude: eLon),
                region: targetRegion,
                pinDiameter: 32
            )
        } else {
            // Uncontrolled initial camera (like the Site Details preview) so the
            // annotations render immediately. A bound `position` with an initial
            // region leaves MapKit not laying out pins until the first camera
            // change (they only appear after a pan); `initialPosition` avoids that.
            Map(initialPosition: .region(targetRegion)) {
                if let entryLat, let entryLon {
                    // Entry only — same green as the combined-map entry pin.
                    Annotation(coordinate: CLLocationCoordinate2D(latitude: entryLat, longitude: entryLon), anchor: .bottom) {
                        MapPointerPin(systemImage: "arrow.down", tint: .green)
                    } label: {
                        if siteName.isEmpty {
                            Text("Entry")
                        } else {
                            Text(verbatim: siteName)
                        }
                    }
                } else if let eLat = exitLat, let eLon = exitLon {
                    // Exit only — same orange as the combined-map exit pin.
                    Annotation(coordinate: CLLocationCoordinate2D(latitude: eLat, longitude: eLon), anchor: .bottom) {
                        MapPointerPin(systemImage: "arrow.up", tint: .orange)
                    } label: {
                        if siteName.isEmpty {
                            Text("Exit")
                        } else {
                            Text(verbatim: siteName)
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            siteMapContent
            .mapStyle(mapStyle)
            .mapControls {
                MapUserLocationButton()
                    .tint(.cyan)
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
                    closeToolbarButton { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Section("Map Style") {
                            Button {
                                mapStyle = .standard(elevation: .realistic)
                            } label: {
                                Label("Standard", systemImage: "map")
                            }
                            Button {
                                mapStyle = .hybrid(elevation: .realistic)
                            } label: {
                                Label("Hybrid", systemImage: "map.fill")
                            }
                            Button {
                                mapStyle = .imagery(elevation: .realistic)
                            } label: {
                                Label("Satellite", systemImage: "globe.americas.fill")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.cyan)
                    }
                    .accessibilityLabel(Text("Map Style"))
                }
            }
        }
    }
}
