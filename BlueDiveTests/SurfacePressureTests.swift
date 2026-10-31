import Foundation
import Testing
@testable import BlueDive

/// `Dive.surfacePressure` (bar, recorded by the computer or a file, never estimated): the
/// validation range, its use by PPO₂/GF instead of the altitude-derived pressure, and the
/// BlueDive XML, UDDF and Subsurface round-trips.
@MainActor
struct SurfacePressureTests {

    // MARK: Validation

    @Test func validatedSurfacePressureKeepsOnlyThePlausibleRange() {
        #expect(Dive.validatedSurfacePressure(1.013) == 1.013)
        #expect(Dive.validatedSurfacePressure(0.4) == 0.4)
        #expect(Dive.validatedSurfacePressure(1.2) == 1.2)
        for bad in [nil, 0, 0.39, 1.21, 1013, -1, .nan, .infinity] as [Double?] {
            #expect(Dive.validatedSurfacePressure(bad) == nil, "\(String(describing: bad))")
        }
    }

    @Test func initStoresOnlyAValidPressure() {
        #expect(Dive(surfacePressure: 0.987).surfacePressure == 0.987)
        #expect(Dive(surfacePressure: 0).surfacePressure == nil)
        #expect(Dive().surfacePressure == nil)
    }

    // MARK: PPO₂ / GF setup

    @Test func setupUsesTheRecordedPressureElseTheAltitude() {
        let recorded = Dive(surfacePressure: 0.85)
        recorded.siteAltitude = 0
        #expect(PPO2Setup(dive: recorded).surfacePressure == 0.85)

        let altitudeOnly = Dive()
        altitudeOnly.siteAltitude = 1500
        #expect(PPO2Setup(dive: altitudeOnly).surfacePressure == atmosphericPressure(forAltitudeMeters: 1500))

        let neither = Dive()
        #expect(PPO2Setup(dive: neither).surfacePressure == atmosphericPressure(forAltitudeMeters: 0))
    }

    // MARK: BlueDive XML

    @Test func blueDiveXMLRoundTripIsLossless() throws {
        let dive = Dive(surfacePressure: 1.0137)
        let xml = BlueDiveXMLExporter.generateXML(for: dive)
        #expect(xml.contains("<surfacePressure>1.0137</surfacePressure>"))
        let parsed = try #require(BlueDiveXMLParser().parse(data: Data(xml.utf8))?.first)
        #expect(parsed.surfacePressure == 1.0137)
    }

    @Test func blueDiveXMLWithoutPressureGivesNil() throws {
        let xml = BlueDiveXMLExporter.generateXML(for: Dive())
        #expect(!xml.contains("<surfacePressure>"))
        let parsed = try #require(BlueDiveXMLParser().parse(data: Data(xml.utf8))?.first)
        #expect(parsed.surfacePressure == nil)
    }

    // MARK: UDDF

    private func uddfXML(_ surfacePressure: String) -> Data {
        Data("""
        <uddf><profiledata><repetitiongroup><dive>\
        <informationbeforedive><surfacepressure>\(surfacePressure)</surfacepressure></informationbeforedive>\
        <informationafterdive><diveduration>2700</diveduration></informationafterdive>\
        </dive></repetitiongroup></profiledata></uddf>
        """.utf8)
    }

    @Test func uddfReadsPascalsAsBar() throws {
        let parsed = try #require(UDDFXMLParser().parse(data: uddfXML("102000.0"))?.first)
        #expect(abs((parsed.surfacePressure ?? 0) - 1.02) < 1e-12)
        let garbage = try #require(UDDFXMLParser().parse(data: uddfXML("0"))?.first)
        #expect(garbage.surfacePressure == nil)
    }

    @Test func uddfRoundTrip() throws {
        let dive = Dive(surfacePressure: 1.0132)
        let uddf = BlueDiveUDDFExporter.generateUDDF(for: dive)
        #expect(uddf.contains("<surfacepressure>101320</surfacepressure>"))
        let parsed = try #require(UDDFXMLParser().parse(data: Data(uddf.utf8))?.first)
        #expect(abs((parsed.surfacePressure ?? 0) - 1.0132) < 1e-12)
        #expect(!BlueDiveUDDFExporter.generateUDDF(for: Dive()).contains("<surfacepressure>"))
    }

    // MARK: Subsurface

    private func subsurfaceXML(_ surface: String) -> Data {
        Data("""
        <divelog program='subsurface' version='3'><dives>\
        <dive number='1' date='2026-10-01' time='08:36:18' duration='45:00 min'>\
        <divecomputer model='Test'>\(surface)</divecomputer>\
        </dive></dives></divelog>
        """.utf8)
    }

    @Test func subsurfaceReadsTheDiveComputersSurfacePressure() throws {
        let parsed = try #require(SubsurfaceXMLParser().parse(data: subsurfaceXML("<surface pressure='1.031 bar' />"))?.first)
        #expect(parsed.surfacePressure == 1.031)
        let none = try #require(SubsurfaceXMLParser().parse(data: subsurfaceXML(""))?.first)
        #expect(none.surfacePressure == nil)
    }
}
