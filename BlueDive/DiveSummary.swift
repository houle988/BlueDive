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
    let gasNames: [String]         // distinct TankData.gasName per tank, in tank order

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
        // Translatable so Dutch gets "u" (uur); same letters as displaySurfaceInterval.
        return String(format: NSLocalizedString("%dh %02dm", bundle: .forAppLanguage(), value: "%dh %02dm", comment: "Compact dive duration: hours and zero-padded minutes, e.g. 0h 42m"), h, m)
    }

    var displaySurfaceInterval: String {
        let locale = UserPreferences.shared.languageMode.locale ?? Locale.current
        // Display only: the stored string keeps the "2d 3h 05m" form it was imported with.
        switch locale.language.languageCode?.identifier {
        case "fr":
            return surfaceInterval.replacingOccurrences(
                of: #"(\d+)d "#,
                with: "$1j ",
                options: .regularExpression
            )
        case "nl":
            // Dutch "u" (uur) for hours, matching shortFormattedDuration; "d" (dag) stays.
            return surfaceInterval.replacingOccurrences(
                of: #"(\d+)h\b"#,
                with: "$1u",
                options: .regularExpression
            )
        default:
            return surfaceInterval
        }
    }

    /// Every gas used on the dive, one per distinct gas in tank order and localized, e.g.
    /// "Trimix + Nitrox". Empty when the dive has no tanks.
    var displayGasNames: String {
        gasNames.map { Self.localizedGasName($0) }.joined(separator: " + ")
    }

    /// Every gas used on a dive, one per distinct gas in tank order (`TankData.gasName`:
    /// "Air", "Nitrox", "Trimix", "Heliox", "Hypoxic"). Empty when the dive has no tanks.
    /// Shared by the summary and the gas filters that work on `Dive`.
    static func gasNames(of dive: Dive) -> [String] {
        var seen = Set<String>()
        return dive.tanks.map(\.gasName).filter { seen.insert($0).inserted }
    }

    /// Localized label for a stored gas name (list and filter chips); the stored English name
    /// stays the value that is compared and filtered on.
    static func localizedGasName(_ name: String) -> String {
        switch name {
        case "Air":
            return NSLocalizedString("Air", bundle: .forAppLanguage(), value: "Air", comment: "Gas type label: 21% oxygen")
        case "Nitrox":
            return NSLocalizedString("Nitrox", bundle: .forAppLanguage(), value: "Nitrox", comment: "Gas type label: oxygen above 21%")
        case "Trimix":
            return NSLocalizedString("Trimix", bundle: .forAppLanguage(), value: "Trimix", comment: "Gas type label: helium present")
        case "Heliox":
            return NSLocalizedString("Heliox", bundle: .forAppLanguage(), value: "Heliox", comment: "Gas type label: oxygen and helium only, no nitrogen")
        case "Hypoxic":
            return NSLocalizedString("Hypoxic", bundle: .forAppLanguage(), value: "Hypoxic", comment: "Gas type label: oxygen below 21%")
        default:
            return name
        }
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
        gasNames = Self.gasNames(of: dive)
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
