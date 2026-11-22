import Foundation

// MARK: - Condition Options

/// The stored values offered by the Edit Conditions pickers (weather, wind, wind direction,
/// surface, current) and their localized labels, shared by the editor, the Conditions card
/// and the PDF logbook. Stored values are English and never translated; the labels go through
/// literal `NSLocalizedString` keys so Xcode extracts each one. Wind values use prefixed keys
/// because their bare English words already exist with another meaning ("Light" = light
/// theme, "Calm" = calm sea).
enum DiveConditionOptions {

    static let weather = ["Sunny", "Clear", "Cloudy", "Overcast", "Fog", "Drizzle", "Rain", "Snow", "Storm", "Variable"]

    /// Beaufort-based groups (see `OpenMeteoWeatherService.windOption(knots:)`).
    static let wind = ["Calm", "Light", "Moderate", "Fresh", "Strong", "Gale"]

    static let windDirection = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    static let surface = ["Calm", "Slightly choppy", "Choppy", "Heavy swell"]

    /// Six levels, matching UDDF's current keywords (no-current … very-hard-current).
    /// `nonisolated` (constant strings) so the UDDF parser, which runs off the main actor, can read it.
    nonisolated static let current = ["None", "Very weak", "Weak", "Moderate", "Strong", "Very strong"]

    /// UDDF's `<current>` keywords, one per `current` option in the same order. Only the
    /// vocabulary differs: the meaning is the same, so the value is not altered.
    nonisolated static let uddfCurrentKeywords = ["no-current", "very-mild-current", "mild-current",
                                                  "moderate-current", "hard-current", "very-hard-current"]

    /// The `current` option for a UDDF keyword; any other text is kept as written.
    nonisolated static func current(fromUDDF keyword: String) -> String {
        uddfCurrentKeywords.firstIndex(of: keyword).map { current[$0] } ?? keyword
    }

    /// The UDDF keyword for a `current` option; nil for a value outside the options (UDDF
    /// accepts only its keywords).
    nonisolated static func uddfCurrentKeyword(for option: String) -> String? {
        current.firstIndex(of: option).map { uddfCurrentKeywords[$0] }
    }

    /// The tide's phase at the dive start, in cycle order: the standard high/low water events
    /// (which tide services report) and the flood/ebb between them.
    static let tideState = ["Low", "Rising", "High", "Falling"]

    static func localizedWeather(_ raw: String) -> String {
        switch raw {
        // Sunny and Clear say when each applies; the stored values stay "Sunny"/"Clear".
        case "Sunny":    return NSLocalizedString("Sunny (Day)", bundle: .forAppLanguage(), value: "Sunny (Day)", comment: "Weather condition: clear sky during the day")
        case "Clear":    return NSLocalizedString("Clear (Night)", bundle: .forAppLanguage(), value: "Clear (Night)", comment: "Weather condition: clear sky at night")
        case "Cloudy":   return NSLocalizedString("Cloudy", bundle: .forAppLanguage(), value: "Cloudy", comment: "")
        case "Overcast": return NSLocalizedString("Overcast", bundle: .forAppLanguage(), value: "Overcast", comment: "")
        case "Fog":      return NSLocalizedString("Fog", bundle: .forAppLanguage(), value: "Fog", comment: "Weather condition")
        case "Drizzle":  return NSLocalizedString("Drizzle", bundle: .forAppLanguage(), value: "Drizzle", comment: "Weather condition")
        case "Rain":     return NSLocalizedString("Rain", bundle: .forAppLanguage(), value: "Rain", comment: "")
        case "Snow":     return NSLocalizedString("Snow", bundle: .forAppLanguage(), value: "Snow", comment: "Weather condition")
        case "Storm":    return NSLocalizedString("Storm", bundle: .forAppLanguage(), value: "Storm", comment: "")
        case "Variable": return NSLocalizedString("Variable", bundle: .forAppLanguage(), value: "Variable", comment: "")
        default:         return raw
        }
    }

    static func localizedSurface(_ raw: String) -> String {
        switch raw {
        case "Calm":            return NSLocalizedString("Calm", bundle: .forAppLanguage(), value: "Calm", comment: "")
        case "Slightly choppy": return NSLocalizedString("Slightly choppy", bundle: .forAppLanguage(), value: "Slightly choppy", comment: "")
        case "Choppy":          return NSLocalizedString("Choppy", bundle: .forAppLanguage(), value: "Choppy", comment: "")
        case "Heavy swell":     return NSLocalizedString("Heavy swell", bundle: .forAppLanguage(), value: "Heavy swell", comment: "")
        default:                return raw
        }
    }

    static func localizedCurrent(_ raw: String) -> String {
        switch raw {
        case "None":        return NSLocalizedString("None", bundle: .forAppLanguage(), value: "None", comment: "")
        case "Very weak":   return NSLocalizedString("Very weak", bundle: .forAppLanguage(), value: "Very weak", comment: "Current strength option in Edit Conditions, between None and Weak")
        case "Weak":        return NSLocalizedString("Weak", bundle: .forAppLanguage(), value: "Weak", comment: "")
        case "Moderate":    return NSLocalizedString("Moderate", bundle: .forAppLanguage(), value: "Moderate", comment: "")
        case "Strong":      return NSLocalizedString("Strong", bundle: .forAppLanguage(), value: "Strong", comment: "")
        case "Very strong": return NSLocalizedString("Very strong", bundle: .forAppLanguage(), value: "Very strong", comment: "")
        default:            return raw
        }
    }

    static func localizedWind(_ raw: String) -> String {
        switch raw {
        case "Calm":     return NSLocalizedString("Wind: Calm", bundle: .forAppLanguage(), value: "Calm", comment: "Wind strength, Beaufort 0")
        case "Light":    return NSLocalizedString("Wind: Light", bundle: .forAppLanguage(), value: "Light", comment: "Wind strength, Beaufort 1–3")
        case "Moderate": return NSLocalizedString("Wind: Moderate", bundle: .forAppLanguage(), value: "Moderate", comment: "Wind strength, Beaufort 4")
        case "Fresh":    return NSLocalizedString("Wind: Fresh", bundle: .forAppLanguage(), value: "Fresh", comment: "Wind strength, Beaufort 5")
        case "Strong":   return NSLocalizedString("Wind: Strong", bundle: .forAppLanguage(), value: "Strong", comment: "Wind strength, Beaufort 6–7")
        case "Gale":     return NSLocalizedString("Wind: Gale", bundle: .forAppLanguage(), value: "Gale", comment: "Wind strength, Beaufort 8 and above")
        default:         return raw
        }
    }

    static func localizedTideState(_ raw: String) -> String {
        switch raw {
        case "Low":     return NSLocalizedString("Tide: Low", bundle: .forAppLanguage(), value: "Low", comment: "Tide state at the dive start: around low water (low tide)")
        case "Rising":  return NSLocalizedString("Tide: Rising", bundle: .forAppLanguage(), value: "Rising", comment: "Tide state at the dive start: the sea level is going up (flood tide)")
        case "High":    return NSLocalizedString("Tide: High", bundle: .forAppLanguage(), value: "High", comment: "Tide state at the dive start: around high water (high tide)")
        case "Falling": return NSLocalizedString("Tide: Falling", bundle: .forAppLanguage(), value: "Falling", comment: "Tide state at the dive start: the sea level is going down (ebb tide)")
        default:        return raw
        }
    }

    static func localizedWindDirection(_ raw: String) -> String {
        switch raw {
        case "N":  return NSLocalizedString("Wind direction: N", bundle: .forAppLanguage(), value: "N", comment: "Compass point abbreviation: north")
        case "NE": return NSLocalizedString("Wind direction: NE", bundle: .forAppLanguage(), value: "NE", comment: "Compass point abbreviation: north-east")
        case "E":  return NSLocalizedString("Wind direction: E", bundle: .forAppLanguage(), value: "E", comment: "Compass point abbreviation: east")
        case "SE": return NSLocalizedString("Wind direction: SE", bundle: .forAppLanguage(), value: "SE", comment: "Compass point abbreviation: south-east")
        case "S":  return NSLocalizedString("Wind direction: S", bundle: .forAppLanguage(), value: "S", comment: "Compass point abbreviation: south")
        case "SW": return NSLocalizedString("Wind direction: SW", bundle: .forAppLanguage(), value: "SW", comment: "Compass point abbreviation: south-west")
        case "W":  return NSLocalizedString("Wind direction: W", bundle: .forAppLanguage(), value: "W", comment: "Compass point abbreviation: west")
        case "NW": return NSLocalizedString("Wind direction: NW", bundle: .forAppLanguage(), value: "NW", comment: "Compass point abbreviation: north-west")
        default:   return raw
        }
    }
}
