import SwiftUI
import MapKit
import CoreLocation

/// Minimum real-world distance the pin must move away from its starting position before
/// `hasInteracted` fires. MapKit can deliver more than one `onMapCameraChange` event while
/// it lays out/settles the initial region or `.automatic` position — none of that is user
/// interaction, but there's no fixed number of settle events to skip. Comparing actual
/// distance moved instead of counting events makes the gate correct regardless of how many
/// settle events MapKit happens to fire.
private let coordinatePickerInteractionThresholdMeters: Double = 10

/// A "drop a pin" GPS coordinate picker: a fixed pin marks the exact center of the screen
/// while the map underneath can be freely panned/zoomed. Takes and returns plain
/// coordinates so it needs no `Dive` or `DiveStore` access — the caller decides which
/// field (entry or exit) the saved coordinate goes into.
struct CoordinatePickerView: View {
    let navigationTitle: LocalizedStringKey
    /// The coordinate currently saved for the field being edited, or nil if unset. Also
    /// used as the initial camera focus, and gates whether Save is enabled immediately
    /// (re-editing an existing point) or only after the user actually moves the map
    /// (placing a brand-new point) — this prevents silently saving an arbitrary default
    /// map center as fabricated GPS data.
    let existingCoordinate: CLLocationCoordinate2D?
    /// Icon and color for the fixed selection pin, matching the icon/color this coordinate
    /// will render with once saved (e.g. the green entry / orange exit markers used on the
    /// real Site Details map) so the picker previews exactly what the user will get.
    let pinIcon: String
    let pinColor: Color
    /// The dive's other coordinate (entry when editing exit, or vice versa), shown as a
    /// reference pin and used as a fallback camera focus when `existingCoordinate` is nil.
    let secondaryCoordinate: CLLocationCoordinate2D?
    let secondaryIcon: String
    let secondaryLabel: LocalizedStringKey?
    let secondaryColor: Color
    let onSave: (CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cameraPosition: MapCameraPosition
    @State private var centerCoordinate: CLLocationCoordinate2D
    @State private var hasInteracted = false
    /// The pin's position the first time a camera event arrives. `nil` until then. Compared
    /// against on every later event to detect real movement — see `hasInteracted`'s handler
    /// below for why this replaced a simple "skip exactly one event" counter.
    @State private var initialCenterCoordinate: CLLocationCoordinate2D?
    @State private var showOverwriteConfirm = false
    @State private var mapStyle: MapStyle = .standard(elevation: .realistic)

    init(navigationTitle: LocalizedStringKey,
         existingCoordinate: CLLocationCoordinate2D?,
         pinIcon: String,
         pinColor: Color,
         secondaryCoordinate: CLLocationCoordinate2D? = nil,
         secondaryIcon: String = "mappin",
         secondaryLabel: LocalizedStringKey? = nil,
         secondaryColor: Color = .secondary,
         onSave: @escaping (CLLocationCoordinate2D) -> Void) {
        self.navigationTitle = navigationTitle
        self.existingCoordinate = existingCoordinate
        self.pinIcon = pinIcon
        self.pinColor = pinColor
        self.secondaryCoordinate = secondaryCoordinate
        self.secondaryIcon = secondaryIcon
        self.secondaryLabel = secondaryLabel
        self.secondaryColor = secondaryColor
        self.onSave = onSave

        let start = existingCoordinate ?? secondaryCoordinate
        let fallbackCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        _centerCoordinate = State(initialValue: start ?? fallbackCenter)
        if let start {
            _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
                center: start,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )))
        } else {
            // A fixed .region here, not .automatic: with neither an existing nor a
            // secondary coordinate to fit to, .automatic has to fit itself around the
            // lone (0, 0) selection pin, which can take more than one settle frame — each
            // one a fresh onMapCameraChange event the distance gate below must not
            // mistake for user interaction. A plain region removes that ambiguity, same
            // as the `start` branch above. Span matches the "zoomed out world view"
            // convention used elsewhere (DiveMapView's default span).
            _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
                center: fallbackCenter,
                span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)
            )))
        }
    }

    private var canSave: Bool { existingCoordinate != nil || hasInteracted }

    private var showsSecondaryPin: Bool {
        guard let secondaryCoordinate else { return false }
        return centerCoordinate.latitude != secondaryCoordinate.latitude
            || centerCoordinate.longitude != secondaryCoordinate.longitude
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $cameraPosition) {
                    // The selection pin is a real coordinate-bound Annotation kept in sync
                    // with the live camera center (below), using the exact same anchor
                    // mechanism as the real saved-coordinate markers elsewhere in the app
                    // (siteMap/SiteMapFullScreenView). A plain floating overlay Image with a
                    // manually-tuned pixel offset previously stood in for this pin, but its
                    // offset was calibrated against screen geometry, not against MapKit's own
                    // anchor projection — so it could silently drift out of sync with where
                    // the coordinate actually renders once saved. Routing both through the
                    // same Annotation call makes them agree by construction.
                    Annotation(coordinate: centerCoordinate, anchor: .bottom) {
                        MapPointerPin(systemImage: pinIcon, tint: pinColor)
                    } label: {
                        EmptyView()
                    }

                    if showsSecondaryPin, let secondaryCoordinate {
                        Annotation(coordinate: secondaryCoordinate, anchor: .bottom) {
                            MapPointerPin(systemImage: secondaryIcon, tint: secondaryColor)
                        } label: {
                            if let secondaryLabel {
                                Text(secondaryLabel)
                            }
                        }
                    }
                }
                .mapStyle(mapStyle)
                .mapControls {
                    MapUserLocationButton()
                        .tint(.cyan)
                    MapCompass()
                    MapScaleView()
                }
                .onMapCameraChange(frequency: .continuous) { context in
                    centerCoordinate = context.region.center
                    guard let initialCenterCoordinate else {
                        // First event of any kind: record where we started, but this alone
                        // is never user interaction.
                        initialCenterCoordinate = centerCoordinate
                        return
                    }
                    let moved = CLLocation(latitude: initialCenterCoordinate.latitude,
                                            longitude: initialCenterCoordinate.longitude)
                        .distance(from: CLLocation(latitude: centerCoordinate.latitude,
                                                    longitude: centerCoordinate.longitude))
                    if moved > coordinatePickerInteractionThresholdMeters {
                        hasInteracted = true
                    }
                }
                .ignoresSafeArea(edges: .bottom)

                VStack {
                    Spacer()
                    coordinateReadout
                        .padding(.bottom, 28)
                }
            }
            .navigationTitle(navigationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if existingCoordinate != nil {
                            showOverwriteConfirm = true
                        } else {
                            commitSave()
                        }
                    }
                    .bold()
                    // A hardcoded .blue here would stay solid blue even while genuinely
                    // disabled below — `.disabled()` only dims a Button's default tint,
                    // not an explicit `.foregroundStyle()` override. Tie the colour to the
                    // same condition so a disabled Save always looks disabled.
                    .foregroundStyle(canSave ? .blue : .secondary)
                    .disabled(!canSave)
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
            .alert("Replace Coordinates", isPresented: $showOverwriteConfirm) {
                Button("Replace", role: .destructive) { commitSave() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will replace the existing coordinates with the pinned location.")
            }
        }
    }

    private func commitSave() {
        onSave(centerCoordinate)
        dismiss()
    }

    private var coordinateReadout: some View {
        VStack(spacing: 4) {
            if !canSave {
                Text("Drag the map to position the pin, then tap Save.")
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            Text(String(format: "%.6f, %.6f", centerCoordinate.latitude, centerCoordinate.longitude))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
    }
}
