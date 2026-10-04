import Foundation

/// Conversions between a dive's stored `timestamp` and the wall-clock time it stands for.
///
/// Every importer stores the dive computer's wall-clock start read in `TimeZone.current`
/// (FIT's UTC times are first shifted by the watch's offset), so the stored `Date` is not
/// the real instant of the dive: the wall-clock components are what was recorded. Shared by
/// the Garmin FIT importer and the Open-Meteo lookup so both read and write that convention
/// the same way.
enum WallClock {

    /// Gregorian calendar in UTC, for fixed-format dates and for wall-clock arithmetic.
    static let utcCalendar: Calendar = calendar(in: TimeZone(secondsFromGMT: 0) ?? .gmt)

    /// Device-zone calendar; follows a change of the device's time zone.
    private static let deviceCalendar: Calendar = calendar(in: .autoupdatingCurrent)

    private static let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]

    /// The wall-clock components a stored dive timestamp represents.
    static func components(ofStored date: Date) -> DateComponents {
        deviceCalendar.dateComponents(fields, from: date)
    }

    /// The stored timestamp for wall-clock components, as every importer stores it.
    static func storedDate(from components: DateComponents) -> Date? {
        deviceCalendar.date(from: components)
    }

    /// Wall-clock components of `instant` shifted by `offset` seconds, read in UTC — e.g. a
    /// FIT UTC time plus the watch's time-zone offset gives the watch's wall-clock time.
    static func components(of instant: Date, offsetFromUTC offset: TimeInterval) -> DateComponents {
        utcCalendar.dateComponents(fields, from: instant.addingTimeInterval(offset))
    }

    /// The real instant of wall-clock components in `timeZone`. In the hour repeated when
    /// clocks go back the first occurrence is used; a time in the hour skipped when clocks go
    /// forward is moved past the gap.
    static func instant(of components: DateComponents, in timeZone: TimeZone) -> Date? {
        calendar(in: timeZone).date(from: components)
    }

    private static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
