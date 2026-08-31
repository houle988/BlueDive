import Foundation

struct DiveSummary: Identifiable, Hashable, Sendable {

    // MARK: - Identity
    let id: UUID
    var diveNumber: Int?

    // MARK: - Scalars (direct column reads, no faults)
    let timestamp: Date
    let diverName: String          // trimmed
    let siteName: String
    let location: String
    let siteCountry: String?
    let siteLatitude: Double?
    let siteLongitude: Double?
    let exitLatitude: Double?
    let exitLongitude: Double?
    let maxDepth: Double           // raw stored value
    let importDistanceUnit: String
    let duration: Int
    var surfaceInterval: String
    let rating: Int
    let buddies: String

    // MARK: - Pre-split facets
    let diveTypes: [String]        // split + trimmed from dive.diveTypes
    let tags: [String]             // split + trimmed from dive.tags
    let year: Int                  // Calendar.component(.year, from: timestamp)
    let gasType: String            // dive.gasType

    // MARK: - Relationship-derived (patched after membership sweep)
    var hasFish: Bool
    var hasPhotos: Bool
    var seenFishNames: [String]

    // MARK: - Computed helpers

    var displayMaxDepth: Double {
        let storedInFeet = importDistanceUnit == "feet"
        let displayInFeet = UserPreferences.shared.depthUnit == .feet
        switch (storedInFeet, displayInFeet) {
        case (false, false): return maxDepth
        case (false, true):  return maxDepth * 3.28084
        case (true,  true):  return maxDepth
        case (true,  false): return maxDepth / 3.28084
        }
    }

    var hasGPSCoordinates: Bool {
        func validPair(_ lat: Double?, _ lon: Double?) -> Bool {
            guard let lat, let lon else { return false }
            return !(lat == 0 && lon == 0)
        }
        return validPair(siteLatitude, siteLongitude) || validPair(exitLatitude, exitLongitude)
    }

    var shortFormattedDuration: String {
        let totalSeconds = (duration >= 3600) ? duration : (duration * 60)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        return String(format: "%dh %02dm", h, m)
    }

    var displaySurfaceInterval: String {
        let locale = UserPreferences.shared.languageMode.locale ?? Locale.current
        guard locale.language.languageCode?.identifier == "fr" else {
            return surfaceInterval
        }
        return surfaceInterval.replacingOccurrences(
            of: #"(\d+)d "#,
            with: "$1j ",
            options: .regularExpression
        )
    }

    // MARK: - Init
    init(from dive: Dive) {
        id = dive.id
        diveNumber = dive.diveNumber
        timestamp = dive.timestamp
        diverName = dive.diverName.trimmingCharacters(in: .whitespaces)
        siteName = dive.siteName
        location = dive.location
        siteCountry = dive.siteCountry
        siteLatitude = dive.siteLatitude
        siteLongitude = dive.siteLongitude
        exitLatitude = dive.exitLatitude
        exitLongitude = dive.exitLongitude
        maxDepth = dive.maxDepth
        importDistanceUnit = dive.importDistanceUnit
        duration = dive.duration
        surfaceInterval = dive.surfaceInterval
        rating = dive.rating
        buddies = dive.buddies
        diveTypes = (dive.diveTypes ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        tags = (dive.tags ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        year = Calendar.current.component(.year, from: dive.timestamp)
        gasType = dive.gasType
        hasFish = false      // patched by store after membership sweep
        hasPhotos = false    // patched by store after membership sweep
        seenFishNames = []   // patched by store after membership sweep
    }

    // Convenience init for standalone call sites (calendar, statistics, trips) that hold a
    // live Dive and know its badge state directly, without going through the store's summary cache.
    init(from dive: Dive, hasFish: Bool, hasPhotos: Bool) {
        self.init(from: dive)
        self.hasFish = hasFish
        self.hasPhotos = hasPhotos
    }
}
