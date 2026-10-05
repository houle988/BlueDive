import Foundation

// MARK: - Open-Meteo Weather Service

/// Values fetched for one dive, already expressed as picker option values and in the dive's
/// stored temperature unit. A nil field means Open-Meteo returned no value for it.
struct FetchedWeather: Sendable {
    var weather: String?
    var airTemperature: Double?
    var wind: String?
    var windDirection: String?

    var isEmpty: Bool {
        weather == nil && airTemperature == nil && wind == nil && windDirection == nil
    }

    /// Writes the fetched values onto `dive`, with the same rules as Edit Conditions' Fetch
    /// Weather: `replaceExisting` replaces every field Open-Meteo returned a value for;
    /// otherwise only empty fields are filled. A field with no returned value is never
    /// touched. Returns whether any value changed. Used where there is no editing sheet
    /// (Bluetooth import); the sheet applies to its working fields instead.
    @discardableResult
    /// `keepAirTemperature`: never replace an existing air temperature (one the dive computer
    /// measured), even when `replaceExisting` is on.
    func apply(to dive: Dive, replaceExisting: Bool, keepAirTemperature: Bool = false) -> Bool {
        var changed = false
        if let weather, replaceExisting || (dive.weather ?? "").isEmpty, dive.weather != weather {
            dive.weather = weather
            changed = true
        }
        if let airTemperature, (replaceExisting && !keepAirTemperature) || dive.airTemperature == nil,
           dive.airTemperature != airTemperature {
            dive.airTemperature = airTemperature
            changed = true
        }
        if let wind, replaceExisting || (dive.wind ?? "").isEmpty, dive.wind != wind {
            dive.wind = wind
            changed = true
        }
        if let windDirection, replaceExisting || (dive.windDirection ?? "").isEmpty, dive.windDirection != windDirection {
            dive.windDirection = windDirection
            changed = true
        }
        return changed
    }
}

extension Dive {
    /// The fields Fetch Weather can fill that are still empty; an empty list means the weather
    /// is complete. A Calm wind has no direction (Open-Meteo returns none), so its empty
    /// direction does not count — otherwise such a dive would be requested again on every
    /// re-download for nothing. The names are for debug logs only (not user-facing, so not
    /// localized).
    nonisolated var emptyWeatherFieldNames: [String] {
        var names: [String] = []
        if (weather ?? "").isEmpty { names.append("weather") }
        if airTemperature == nil { names.append("air temperature") }
        if (wind ?? "").isEmpty { names.append("wind") }
        if (windDirection ?? "").isEmpty && wind != "Calm" { names.append("wind direction") }
        return names
    }
}

enum OpenMeteoWeatherError: Error {
    /// The request could not be made or completed (no connection, timeout, no HTTP response).
    case requestFailed
    /// Open-Meteo answered with an error (e.g. rate limit, server error) or a response that
    /// could not be read.
    case serviceUnavailable
    /// Open-Meteo has no data for the dive's date and hour (e.g. a future date).
    case noData
}

/// Looks up the historical weather for a dive from Open-Meteo (https://open-meteo.com),
/// which needs no API key. Data is licensed CC BY 4.0 and must be attributed where shown.
///
/// The dive's timestamp is the dive computer's wall-clock time, read in `TimeZone.current`
/// on import. With `timezone=auto` the response names the site's time zone, which turns that
/// wall-clock time into the real instant for the dive's date (daylight saving included). The
/// response labels every row with one fixed offset (`utc_offset_seconds`) — observed to be
/// the site's offset *today*, not on the dive date — so the row is found from the instant
/// plus that offset, never from the dive's wall-clock text.
enum OpenMeteoWeatherService {

    /// Entry coordinates, or the exit coordinates when the entry is missing or the (0, 0)
    /// "no GPS" sentinel.
    nonisolated static func coordinate(for dive: Dive) -> (latitude: Double, longitude: Double)? {
        func valid(_ lat: Double?, _ lon: Double?) -> (latitude: Double, longitude: Double)? {
            guard let lat, let lon, lat.isFinite, lon.isFinite, !(lat == 0 && lon == 0) else { return nil }
            return (lat, lon)
        }
        return valid(dive.siteLatitude, dive.siteLongitude) ?? valid(dive.exitLatitude, dive.exitLongitude)
    }

    /// Fetches the weather for the hourly row nearest the dive start: temperature and wind
    /// are instantaneous at the row's hour, and the weather code covers the hour before it.
    static func fetch(for dive: Dive) async throws -> FetchedWeather {
        guard let coordinate = coordinate(for: dive) else { throw OpenMeteoWeatherError.noData }

        // The start as shown on the dive computer, independent of any time zone.
        let wallClock = WallClock.components(ofStored: dive.timestamp)
        guard let wallClockAsUTC = WallClock.utcCalendar.date(from: wallClock) else { throw OpenMeteoWeatherError.noData }
        // No time zone is more than 14 h ahead of UTC, so a wall-clock time more than 14 h
        // after now is in the future wherever the site is: reject it without sending the
        // dive's coordinates anywhere. Nearer cases are checked once the site's zone is known.
        guard wallClockAsUTC.addingTimeInterval(-14 * 3600) <= Date.now else { throw OpenMeteoWeatherError.noData }

        // One day either side, so the matching row is present even when the nearest hour or
        // the response's fixed offset moves it across midnight.
        let startDate = dayString(wallClockAsUTC.addingTimeInterval(-86_400))
        let endDate = dayString(wallClockAsUTC.addingTimeInterval(86_400))

        // Open-Meteo only offers °C and °F; a Kelvin dive gets °C converted below.
        let storedUnit = dive.storedTemperatureUnit

        // The archive covers dates up to today and rejects a range ending after today (HTTP
        // 400); the forecast API then serves recent days. Try the archive first.
        var match: (hourly: Hourly, index: Int)?
        for endpoint in ["https://archive-api.open-meteo.com/v1/archive", "https://api.open-meteo.com/v1/forecast"] {
            guard let response = try await requestHourly(endpoint: endpoint, latitude: coordinate.latitude,
                                                         longitude: coordinate.longitude,
                                                         startDate: startDate, endDate: endDate,
                                                         fahrenheit: storedUnit == .fahrenheit),
                  let hourly = response.hourly,
                  let offset = response.utcOffsetSeconds else { continue }

            // The dive's real instant, from its wall-clock time in the site's time zone. In the
            // hour repeated when clocks go back the wall-clock time is ambiguous and the first
            // occurrence is used: nothing recorded tells which one the dive was in.
            // Offshore (outside territorial waters) Open-Meteo returns a fixed sea zone such as
            // "Etc/GMT+6" (verified: Flower Garden Banks, off Texas), which has no daylight
            // saving. A dive computer set to the nearby coast's summer time is then read one
            // hour off and the next row is used. Accepted: the response names no coastal zone,
            // and looking one up would send the coordinates to another service.
            let siteZone = response.timezone.flatMap(TimeZone.init(identifier:))
                ?? TimeZone(secondsFromGMT: offset) ?? .gmt
            guard let instant = WallClock.instant(of: wallClock, in: siteZone) else { continue }

            // A dive later than now has no observed weather; the forecast API would return a
            // forecast, which must not be stored as the dive's weather.
            guard instant <= Date.now else { throw OpenMeteoWeatherError.noData }

            // Rows are whole hours in the response's local time, so round there: rounding in UTC
            // would pick a row up to an hour off in half-hour zones (India, Newfoundland, …).
            let offsetSeconds = TimeInterval(offset)
            var rowLocal = ((instant.timeIntervalSince1970 + offsetSeconds) / 3600).rounded() * 3600
            // A dive that started under 30 minutes ago would round to an hour still to come,
            // whose values are a forecast; take the previous row then. That row is at or before
            // the start, which the guard above keeps at or before now.
            if rowLocal - offsetSeconds > Date.now.timeIntervalSince1970 { rowLocal -= 3600 }
            let label = rowLabel(Date(timeIntervalSince1970: rowLocal))
            if let index = hourly.time.firstIndex(of: label), hourly.hasValue(at: index) {
                match = (hourly, index)
                break
            }
        }
        guard let (hourly, index) = match else { throw OpenMeteoWeatherError.noData }

        var result = FetchedWeather()
        if let code = hourly.weatherCode?.value(at: index).flatMap({ Int(exactly: $0.rounded()) }) {
            let isDay = hourly.isDay?.value(at: index).map { $0 != 0 }
            result.weather = weatherOption(code: code, isDay: isDay)
        }
        if let temperature = hourly.temperature?.value(at: index) {
            result.airTemperature = storedUnit == .kelvin ? temperature + 273.15 : temperature
        }
        if let knots = hourly.windSpeed?.value(at: index) {
            let wind = windOption(knots: knots)
            result.wind = wind
            // A direction means nothing in calm air.
            if wind != "Calm", let degrees = hourly.windDirection?.value(at: index) {
                result.windDirection = compassPoint(degrees: degrees)
            }
        }
        if result.isEmpty { throw OpenMeteoWeatherError.noData }
        return result
    }

    // MARK: Dates (fixed formats: API parameters, not displayed text)

    /// "yyyy-MM-dd" of a date read in UTC.
    private static func dayString(_ date: Date) -> String {
        let c = WallClock.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Open-Meteo row label ("yyyy-MM-ddTHH:00") of a date read in UTC.
    private static func rowLabel(_ date: Date) -> String {
        let c = WallClock.utcCalendar.dateComponents([.hour], from: date)
        return String(format: "%@T%02d:00", dayString(date), c.hour ?? 0)
    }

    // MARK: Mapping (pure)

    /// WMO weather code → Weather option. "Variable" is never produced: one hourly reading
    /// cannot describe changing weather.
    static func weatherOption(code: Int, isDay: Bool?) -> String? {
        switch code {
        case 0, 1:            return isDay == false ? "Clear" : "Sunny"
        case 2:               return "Cloudy"
        case 3:               return "Overcast"
        case 45, 48:          return "Fog"
        case 51...57:         return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99:         return "Storm"
        default:              return nil
        }
    }

    /// Wind speed in knots → Beaufort-based Wind option. The scale is defined on whole knots.
    static func windOption(knots: Double) -> String {
        let k = knots.rounded()
        switch k {
        case ..<1:    return "Calm"      // Beaufort 0
        case ..<11:   return "Light"     // Beaufort 1–3 (1–10 kn)
        case ..<17:   return "Moderate"  // Beaufort 4 (11–16 kn)
        case ..<22:   return "Fresh"     // Beaufort 5 (17–21 kn)
        case ..<34:   return "Strong"    // Beaufort 6–7 (22–33 kn)
        default:      return "Gale"      // Beaufort 8+ (34 kn and above)
        }
    }

    /// Direction the wind blows from, in degrees → 8-point compass option.
    static func compassPoint(degrees: Double) -> String? {
        guard degrees.isFinite else { return nil }
        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        guard let sector = Int(exactly: ((normalized + 22.5) / 45).rounded(.down)) else { return nil }
        return DiveConditionOptions.windDirection[sector % 8]
    }

    // MARK: Request

    /// Ephemeral session: no disk cache, cookies or credentials, so the dive coordinates and
    /// dates in request URLs are never written to the app's on-disk URL cache.
    private static let session = URLSession(configuration: .ephemeral)

    private struct Response: Decodable {
        let timezone: String?
        let utcOffsetSeconds: Int?
        let hourly: Hourly?

        enum CodingKeys: String, CodingKey {
            case timezone
            case utcOffsetSeconds = "utc_offset_seconds"
            case hourly
        }
    }

    private struct Hourly: Decodable {
        let time: [String]
        let temperature: [Double?]?
        let weatherCode: [Double?]?
        let isDay: [Double?]?
        let windSpeed: [Double?]?
        let windDirection: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time
            case temperature   = "temperature_2m"
            case weatherCode   = "weather_code"
            case isDay         = "is_day"
            case windSpeed     = "wind_speed_10m"
            case windDirection = "wind_direction_10m"
        }

        func hasValue(at index: Int) -> Bool {
            [temperature, weatherCode, windSpeed].contains { $0?.value(at: index) != nil }
        }
    }

    /// Returns nil on HTTP 400 (e.g. a date outside the range this API covers), so the caller
    /// can try the next API. Throws `.serviceUnavailable` on any other non-200 status or an
    /// unreadable response, and `.requestFailed` (or CancellationError) on a network failure.
    private static func requestHourly(endpoint: String, latitude: Double, longitude: Double,
                                      startDate: String, endDate: String,
                                      fahrenheit: Bool) async throws -> Response? {
        guard var components = URLComponents(string: endpoint) else { throw OpenMeteoWeatherError.requestFailed }
        // Fixed "." notation: these are API parameters, not displayed numbers.
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.6f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.6f", longitude)),
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day,wind_speed_10m,wind_direction_10m"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "wind_speed_unit", value: "kn"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        guard let url = components.url else { throw OpenMeteoWeatherError.requestFailed }

        // Short timeout: the sheet's weather fields and Save stay locked while a fetch runs.
        let request = URLRequest(url: url, timeoutInterval: 15)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw OpenMeteoWeatherError.requestFailed
        }
        guard let http = response as? HTTPURLResponse else { throw OpenMeteoWeatherError.requestFailed }
        // 400 = parameter out of range (date not covered by this API); let the caller move on.
        if http.statusCode == 400 { return nil }
        guard http.statusCode == 200 else { throw OpenMeteoWeatherError.serviceUnavailable }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw OpenMeteoWeatherError.serviceUnavailable
        }
    }
}

private extension Array where Element == Double? {
    func value(at index: Int) -> Double? {
        indices.contains(index) ? self[index] : nil
    }
}
