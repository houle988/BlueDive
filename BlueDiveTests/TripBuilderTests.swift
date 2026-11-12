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

    /// The countries a trip card shows: most dives first, ties in date order, one entry per
    /// country (its most common spelling), dives without a country left out.
    @Test func tripCountriesAreRankedByDives() {
        let dives = [
            dive(day: 1, country: "Germany"),
            dive(day: 2, country: "Switzerland"),
            dive(day: 3, country: "switzerland "),
            dive(day: 4, country: "Switzerland"),
            dive(day: 5),
            dive(day: 6, country: "France"),
            dive(day: 7, country: "Germany"),
            dive(day: 8, country: "Italy"),
        ]
        let trip = TripBuilder.buildTrips(from: dives, maxGapDays: 3, splitOnCountryChange: false)
        #expect(trip.map(\.countries) == [["Switzerland", "Germany", "France", "Italy"]])
    }

    @Test func aTripWithoutCountriesHasNone() {
        let trip = TripBuilder.buildTrips(from: [dive(day: 1), dive(day: 2, country: " ")], maxGapDays: 3, splitOnCountryChange: false)
        #expect(trip.map(\.countries) == [[]])
    }

    /// The name of the single trip these dives form.
    private func tripName(_ dives: [Dive]) -> String? {
        TripBuilder.buildTrips(from: dives, maxGapDays: 3, splitOnCountryChange: false).first?.name
    }

    private func dive(day: Int, location: String, site: String = "", country: String? = nil) -> Dive {
        let dive = dive(day: day, country: country)
        dive.location = location
        dive.siteName = site
        return dive
    }

    /// Empty locations are skipped, even when most dives have none.
    @Test func theNameSkipsEmptyLocations() {
        let dives = [dive(day: 1, location: ""), dive(day: 2, location: " "), dive(day: 3, location: "Reef Town")]
        #expect(tripName(dives) == "Reef Town 2030")
    }

    /// A tie goes to the earliest location, whatever the build.
    @Test func aTiedNameGoesToTheEarliestLocation() {
        let dives = [dive(day: 1, location: "North Bay"), dive(day: 2, location: "South Bay"),
                     dive(day: 3, location: "South Bay"), dive(day: 4, location: "North Bay")]
        for _ in 0..<20 { #expect(tripName(dives) == "North Bay 2030") }
    }

    /// Without any location, the site names the trip, then the country.
    @Test func theNameFallsBackToTheSiteThenTheCountry() {
        #expect(tripName([dive(day: 1, location: "", site: "Coral Garden", country: "Egypt")]) == "Coral Garden 2030")
        #expect(tripName([dive(day: 1, location: "", site: "", country: "Egypt")]) == "Egypt 2030")
    }

    /// A trip with nothing to name it after still gets a name, never a lone year.
    @Test func aTripWithoutPlacesStillHasAName() {
        let name = tripName([dive(day: 1, location: "")]) ?? ""
        #expect(name.hasSuffix(" 2030"))
        #expect(name.count > " 2030".count)
    }

    /// The gap still applies when the country stays the same.
    @Test func theGapStillSplitsWithinOneCountry() {
        let dives = [dive(day: 1, country: "Egypt"), dive(day: 10, country: "Egypt")]
        #expect(trips(dives, gap: 3, splitOnCountry: true) == [[1], [10]])
    }
}
