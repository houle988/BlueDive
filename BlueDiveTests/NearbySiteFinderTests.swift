import CoreLocation
import Foundation
import Testing
@testable import BlueDive

/// `NearbySiteFinder`: the Nearby suggestions of Edit Site Details → Copy from Existing Site.
/// All coordinates and site names are made up.
@MainActor
struct NearbySiteFinderTests {

    /// About 1 m of latitude, in degrees.
    private let metre = 1.0 / 111_320

    private let reference = CLLocationCoordinate2D(latitude: 10, longitude: 20)

    private func summary(_ name: String,
                         entry: (Double, Double)? = nil,
                         exit: (Double, Double)? = nil,
                         id: UUID = UUID()) -> DiveSummary {
        let dive = Dive()
        dive.id = id
        dive.siteName = name
        dive.siteLatitude = entry?.0
        dive.siteLongitude = entry?.1
        dive.exitLatitude = exit?.0
        dive.exitLongitude = exit?.1
        return DiveSummary(from: dive)
    }

    /// A point `metres` north of the reference.
    private func north(_ metres: Double) -> (Double, Double) {
        (reference.latitude + metres * metre, reference.longitude)
    }

    private func find(_ summaries: [DiveSummary], excluding id: UUID = UUID()) -> [NearbySite] {
        NearbySiteFinder.nearbySites(to: reference, in: summaries, excluding: id)
    }

    @Test func keepsOnlySitesWithinTheRadius() {
        let result = find([summary("Inside", entry: north(150)), summary("Outside", entry: north(260))])
        #expect(result.map(\.siteName) == ["Inside"])
        #expect(abs((result.first?.distanceMeters ?? 0) - 150) < 2)
    }

    @Test func sortsClosestFirstAndKeepsThree() {
        let result = find([
            summary("D", entry: north(190)),
            summary("A", entry: north(10)),
            summary("C", entry: north(120)),
            summary("B", entry: north(60)),
        ])
        #expect(result.map(\.siteName) == ["A", "B", "C"])
    }

    @Test func excludesTheEditedDive() {
        let id = UUID()
        #expect(find([summary("Self", entry: north(5), id: id)], excluding: id).isEmpty)
    }

    @Test func skipsMissingSentinelAndInvalidCoordinates() {
        let result = find([
            summary("None"),
            summary("Zero", entry: (0, 0)),
            summary("OutOfRange", entry: (95, 20)),
            summary("NotFinite", entry: (.nan, 20)),
        ])
        #expect(result.isEmpty)
        // A (0, 0) or invalid reference finds nothing.
        #expect(NearbySiteFinder.nearbySites(to: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                             in: [summary("Origin", entry: (0, 0.0001))],
                                             excluding: UUID()).isEmpty)
    }

    @Test func usesTheExitPointWithoutAnEntryPoint() {
        let result = find([summary("ExitOnly", exit: north(40)),
                           summary("EntryFar", entry: north(500), exit: north(20))])
        // The entry point wins when valid, even if the exit point is closer.
        #expect(result.map(\.siteName) == ["ExitOnly"])
    }

    @Test func oneSitePerNameKeepingTheClosestDive() {
        let close = UUID()
        let result = find([
            summary("Reef", entry: north(150)),
            summary("  reef ", entry: north(30), id: close),
            summary("REEF", entry: north(90)),
        ])
        #expect(result.count == 1)
        #expect(result.first?.diveID == close)
    }

    @Test func skipsDivesWithoutASiteName() {
        #expect(find([summary("   ", entry: north(10))]).isEmpty)
    }

    @Test func findsSitesAcrossThe180thMeridian() {
        let east = CLLocationCoordinate2D(latitude: -17, longitude: 179.9995)
        let result = NearbySiteFinder.nearbySites(to: east,
                                                  in: [summary("West", entry: (-17, -179.9995))],
                                                  excluding: UUID())
        #expect(result.map(\.siteName) == ["West"])
    }

    @Test func keepsAnEastWestNeighbourAtHighLatitude() {
        // At 70° a longitude degree is about a third of a latitude degree: the prefilter box
        // must widen with latitude, or this site 180 m east would be dropped.
        let polar = CLLocationCoordinate2D(latitude: 70, longitude: 20)
        let lonOffset = 180 / (111_320 * cos(70 * Double.pi / 180))
        let result = NearbySiteFinder.nearbySites(to: polar,
                                                  in: [summary("East", entry: (70, 20 + lonOffset))],
                                                  excluding: UUID())
        #expect(result.map(\.siteName) == ["East"])
    }
}
