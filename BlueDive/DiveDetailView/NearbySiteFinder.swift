import CoreLocation
import Foundation

/// A site dived near a reference point: the closest dive recorded under that site name.
struct NearbySite: Hashable, Sendable {
    /// The dive whose site information is copied.
    let summary: DiveSummary
    let distanceMeters: Double

    var diveID: UUID { summary.id }
    var siteName: String { summary.siteName }
}

/// Finds the sites of other dives near a point (Edit Site Details → Copy from Existing Site →
/// Nearby). Works on `DiveSummary` values only, so no dive is read or faulted.
enum NearbySiteFinder {

    /// Sites within this distance of the dive are suggested.
    static let radiusMeters: Double = 200

    /// Up to `limit` sites within `radiusMeters` of `reference`, closest first, one per site
    /// name (case and surrounding spaces ignored, as the Recent list does), each represented
    /// by its closest dive. A dive is placed at its entry point, else its exit point; the dive
    /// `excluding` and dives without a site name are skipped.
    static func nearbySites(to reference: CLLocationCoordinate2D,
                            in summaries: [DiveSummary],
                            excluding diveID: UUID,
                            radiusMeters: Double = radiusMeters,
                            limit: Int = 3) -> [NearbySite] {
        guard isValidCoordinate(reference.latitude, reference.longitude), limit > 0 else { return [] }
        let origin = CLLocation(latitude: reference.latitude, longitude: reference.longitude)
        // A degree box slightly larger than the radius discards far dives before the exact
        // distance is computed. Longitude degrees shrink towards the poles.
        let latSpan = radiusMeters * 1.5 / 111_320
        let lonSpan = latSpan / max(cos(reference.latitude * .pi / 180), 0.01)

        var closestByName: [String: NearbySite] = [:]
        for summary in summaries where summary.id != diveID {
            let key = nameKey(summary.siteName)
            guard !key.isEmpty, let point = position(of: summary) else { continue }
            guard abs(point.latitude - reference.latitude) <= latSpan,
                  longitudeDifference(point.longitude, reference.longitude) <= lonSpan else { continue }
            let distance = origin.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
            guard distance <= radiusMeters else { continue }
            if let existing = closestByName[key], existing.distanceMeters <= distance { continue }
            closestByName[key] = NearbySite(summary: summary, distanceMeters: distance)
        }
        return Array(closestByName.values
            .sorted { $0.distanceMeters == $1.distanceMeters
                ? $0.siteName.localizedCaseInsensitiveCompare($1.siteName) == .orderedAscending
                : $0.distanceMeters < $1.distanceMeters }
            .prefix(limit))
    }

    /// The name key `nearbySites` dedupes by, so other lists can leave those sites out.
    static func nameKey(_ siteName: String) -> String {
        siteName.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The entry point when valid, else the exit point when valid.
    private static func position(of summary: DiveSummary) -> CLLocationCoordinate2D? {
        if let lat = summary.siteLatitude, let lon = summary.siteLongitude, isValidCoordinate(lat, lon) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        if let lat = summary.exitLatitude, let lon = summary.exitLongitude, isValidCoordinate(lat, lon) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    /// Finite, in range and not the (0, 0) "no GPS" sentinel. Invalid values are skipped,
    /// never corrected.
    static func isValidCoordinate(_ lat: Double, _ lon: Double) -> Bool {
        lat.isFinite && lon.isFinite && abs(lat) <= 90 && abs(lon) <= 180 && !(lat == 0 && lon == 0)
    }

    /// The east–west difference taken the short way round, so points either side of the 180°
    /// meridian are close.
    private static func longitudeDifference(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b)
        return difference > 180 ? 360 - difference : difference
    }
}
