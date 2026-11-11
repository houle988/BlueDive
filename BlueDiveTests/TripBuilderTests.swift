import Foundation
import Testing
@testable import BlueDive

/// `TripBuilder`: how My Trips (and the PDF logbook's Trip field) group dives into trips.
/// All dates and countries are made up.
@MainActor
struct TripBuilderTests {

    /// A dive at noon on the given day of an arbitrary month (noon keeps whole-day gaps whole
    /// across a daylight saving change).
    private func dive(day: Int, hour: Int = 12, country: String? = nil) -> Dive {
        let dive = Dive()
        var components = DateComponents()
        components.year = 2030
        components.month = 3
        components.day = day
        components.hour = hour
        dive.timestamp = Calendar.current.date(from: components) ?? .now
        dive.siteCountry = country
        return dive
    }

    /// The trips, oldest first, each as the days of its dives.
    private func trips(_ dives: [Dive], gap: Int = 3, splitOnCountry: Bool = false) -> [[Int]] {
        TripBuilder.buildTrips(from: dives, maxGapDays: gap, splitOnCountryChange: splitOnCountry)
            .reversed()
            .map { trip in trip.dives.map { Calendar.current.component(.day, from: $0.timestamp) } }
    }

    @Test func noDivesGiveNoTrips() {
        #expect(trips([]).isEmpty)
    }

    @Test func aGapAtTheLimitJoinsAndOneDayMoreSplits() {
        #expect(trips([dive(day: 1), dive(day: 4)], gap: 3) == [[1, 4]])
        #expect(trips([dive(day: 1), dive(day: 5)], gap: 3) == [[1], [5]])
    }

    /// The gap is measured from the previous dive, not from the trip's first dive.
    @Test func theGapIsBetweenConsecutiveDives() {
        #expect(trips([dive(day: 1), dive(day: 4), dive(day: 7), dive(day: 10)], gap: 3) == [[1, 4, 7, 10]])
    }

    /// Whole 24-hour periods: 3 days and 20 hours still counts as 3 days.
    @Test func partOfADayDoesNotCount() {
        #expect(trips([dive(day: 1, hour: 8), dive(day: 4, hour: 23)], gap: 3) == [[1, 4]])
    }

    @Test func diveOrderDoesNotMatter() {
        #expect(trips([dive(day: 20), dive(day: 1), dive(day: 2)], gap: 3) == [[1, 2], [20]])
    }

    @Test func countriesAreIgnoredWhenTheSplitIsOff() {
        #expect(trips([dive(day: 1, country: "Egypt"), dive(day: 2, country: "Switzerland")]) == [[1, 2]])
    }

    @Test func aCountryChangeStartsANewTrip() {
        let dives = [dive(day: 1, country: "Egypt"), dive(day: 2, country: "Egypt"), dive(day: 3, country: "Switzerland")]
        #expect(trips(dives, splitOnCountry: true) == [[1, 2], [3]])
    }

    @Test func countriesCompareIgnoringCaseAndSpaces() {
        let dives = [dive(day: 1, country: "Egypt"), dive(day: 2, country: " egypt ")]
        #expect(trips(dives, splitOnCountry: true) == [[1, 2]])
    }

    @Test func aDiveWithoutACountryNeverSplitsATrip() {
        let dives = [dive(day: 1, country: "Egypt"), dive(day: 2), dive(day: 3, country: ""), dive(day: 4, country: "Egypt")]
        #expect(trips(dives, splitOnCountry: true) == [[1, 2, 3, 4]])
    }

    /// A dive without a country between two countries does not let them share a trip.
    @Test func aDiveWithoutACountryDoesNotBridgeTwoCountries() {
        let dives = [dive(day: 1, country: "Egypt"), dive(day: 2), dive(day: 3, country: "Switzerland")]
        #expect(trips(dives, splitOnCountry: true) == [[1, 2], [3]])
    }

    /// A trip that starts without a country takes the first country it meets.
    @Test func aTripStartingWithoutACountryTakesTheFirstOne() {
        let dives = [dive(day: 1), dive(day: 2, country: "Egypt"), dive(day: 3, country: "Switzerland")]
        #expect(trips(dives, splitOnCountry: true) == [[1, 2], [3]])
    }

    /// The gap still applies when the country stays the same.
    @Test func theGapStillSplitsWithinOneCountry() {
        let dives = [dive(day: 1, country: "Egypt"), dive(day: 10, country: "Egypt")]
        #expect(trips(dives, gap: 3, splitOnCountry: true) == [[1], [10]])
    }
}
