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

    static let current = ["None", "Weak", "Moderate", "Strong", "Very strong"]

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
