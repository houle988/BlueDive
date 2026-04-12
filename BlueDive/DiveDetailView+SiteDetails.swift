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

            // GPS Coordinates
            if let lat = dive.siteLatitude, let lon = dive.siteLongitude {
                conditionRow(icon: "location.circle.fill", color: .green, label: "Coordinates",
                            value: String(format: "%.6f, %.6f", lat, lon))

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

                Divider().background(.primary.opacity(0.2))

                // Map view
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))) {
                    if dive.siteName.isEmpty {
                        Marker("Dive Site", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    } else {
                        Marker(dive.siteName, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    }
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            } else {
                conditionRow(icon: "location.circle.fill", color: .green, label: "Coordinates",
                            value: "—")

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
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
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
