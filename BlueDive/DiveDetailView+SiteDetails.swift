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
                        value: dive.siteWaterType?.isEmpty == false ? dive.siteWaterType! : "—")

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
                let depthUnit = prefs.depthUnit == .feet ? "ft" : "m"
                conditionRow(icon: "mountain.2.fill", color: .brown, label: "Altitude",
                            value: String(format: "%.0f %@", alt, depthUnit))
            } else {
                conditionRow(icon: "mountain.2.fill", color: .brown, label: "Altitude",
                            value: "—")
            }

            // Map view
            if let lat = dive.siteLatitude, let lon = dive.siteLongitude {
                Divider().background(.primary.opacity(0.2))

                siteMap(entryLat: lat, entryLon: lon,
                        exitLat: dive.exitLatitude, exitLon: dive.exitLongitude)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
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
