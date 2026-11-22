import Foundation
import Testing
@testable import BlueDive

/// `Dive.tideHeight` (entered from a local tide table: above chart datum, in the dive's distance
/// unit) and `Dive.tideState`: the validation ranges per unit, the display sign, the BlueDive XML
/// round-trip, and file round-trips through the import's `Dive` construction (`ContentView.makeDive`):
/// BlueDive XML keeps the tide and current, UDDF keeps only the current. All values are made up.
@MainActor
struct TideTests {

    // MARK: Validation

    @Test func validatedTideHeightKeepsOnlyThePlausibleRangeInMetres() {
        #expect(Dive.validatedTideHeight(2.1, inFeet: false) == 2.1)
        #expect(Dive.validatedTideHeight(-0.3, inFeet: false) == -0.3)
        #expect(Dive.validatedTideHeight(0, inFeet: false) == 0)
        #expect(Dive.validatedTideHeight(-5, inFeet: false) == -5)
        #expect(Dive.validatedTideHeight(20, inFeet: false) == 20)
        for bad in [nil, -5.01, 20.01, 40, .nan, .infinity, -.infinity] as [Double?] {
            #expect(Dive.validatedTideHeight(bad, inFeet: false) == nil, "\(String(describing: bad))")
        }
    }

    @Test func validatedTideHeightKeepsOnlyThePlausibleRangeInFeet() {
        #expect(Dive.validatedTideHeight(6.9, inFeet: true) == 6.9)
        #expect(Dive.validatedTideHeight(40, inFeet: true) == 40)
        #expect(Dive.validatedTideHeight(-15, inFeet: true) == -15)
        #expect(Dive.validatedTideHeight(65, inFeet: true) == 65)
        for bad in [nil, -15.01, 65.01, 120, .nan, .infinity] as [Double?] {
            #expect(Dive.validatedTideHeight(bad, inFeet: true) == nil, "\(String(describing: bad))")
        }
    }

    @Test func initValidatesInTheDivesDistanceUnit() {
        #expect(Dive(tideHeight: 2.1, tideState: "Falling").tideHeight == 2.1)
        #expect(Dive(tideHeight: 2.1, tideState: "Falling").tideState == "Falling")
        // 40 is plausible in feet, not in metres; stored as given, never converted.
        #expect(Dive(tideHeight: 40).tideHeight == nil)
        #expect(Dive(importDistanceUnit: "feet", tideHeight: 40).tideHeight == 40)
        #expect(Dive().tideHeight == nil)
        #expect(Dive().tideState == nil)
    }

    // MARK: Display

    /// As a tide table shows it: no "+" sign, a minus only for a value below chart datum.
    /// Checked on the sign only, so the test holds in any region and depth unit.
    @Test func formattedTideHeightShowsAMinusOnlyBelowChartDatum() throws {
        let positive = try #require(Dive(tideHeight: 2.1).formattedTideHeight)
        #expect(!positive.hasPrefix("+") && !positive.hasPrefix("−") && !positive.hasPrefix("-"))
        let negative = try #require(Dive(tideHeight: -0.3).formattedTideHeight)
        #expect(negative.hasPrefix("−"))
        // Rounds to zero: no sign.
        let nearZero = try #require(Dive(tideHeight: -0.001).formattedTideHeight)
        #expect(!nearZero.hasPrefix("−"))
        #expect(Dive().formattedTideHeight == nil)
    }

    // MARK: BlueDive XML

    @Test func blueDiveXMLRoundTripIsLossless() throws {
        let dive = Dive(tideHeight: 2.4271, tideState: "High")
        let xml = BlueDiveXMLExporter.generateXML(for: dive)
        #expect(xml.contains("<tideHeight>2.4271</tideHeight>"))
        #expect(xml.contains("<tideState>High</tideState>"))
        let parsed = try #require(BlueDiveXMLParser().parse(data: Data(xml.utf8))?.first)
        #expect(parsed.tideHeight == 2.4271)
        #expect(parsed.tideState == "High")
    }

    @Test func blueDiveXMLRoundTripKeepsFeet() throws {
        let dive = Dive(importDistanceUnit: "feet", tideHeight: -0.625, tideState: "Rising")
        let xml = BlueDiveXMLExporter.generateXML(for: dive)
        #expect(xml.contains("<distanceFormat>feet</distanceFormat>"))
        #expect(xml.contains("<tideHeight>-0.625</tideHeight>"))
        let parsed = try #require(BlueDiveXMLParser().parse(data: Data(xml.utf8))?.first)
        #expect(parsed.distanceFormat == "feet")
        #expect(parsed.tideHeight == -0.625)
    }

    @Test func blueDiveXMLWithoutTideGivesNil() throws {
        let xml = BlueDiveXMLExporter.generateXML(for: Dive())
        #expect(!xml.contains("<tideHeight>"))
        #expect(!xml.contains("<tideState>"))
        let parsed = try #require(BlueDiveXMLParser().parse(data: Data(xml.utf8))?.first)
        #expect(parsed.tideHeight == nil)
        #expect(parsed.tideState == nil)
    }

    // MARK: File round-trips (through the import's Dive construction)

    /// A dive with every new conditions field, as the user would enter it.
    private func diveWithNewFields(unit: String) -> Dive {
        Dive(current: "Very weak", importDistanceUnit: unit, tideHeight: 40, tideState: "High")
    }

    /// BlueDive XML keeps all three fields, and the file's <distanceFormat> reaches the
    /// validation: 40 is a valid tide height in feet.
    @Test func blueDiveXMLImportKeepsEveryNewField() throws {
        let xml = BlueDiveXMLExporter.generateXML(for: diveWithNewFields(unit: "feet"))
        let parsed = try #require(BlueDiveXMLParser().parse(data: Data(xml.utf8))?.first)
        let imported = ContentView.makeDive(from: parsed)
        #expect(imported.importDistanceUnit == "feet")
        #expect(imported.tideHeight == 40)
        #expect(imported.tideState == "High")
        #expect(imported.current == "Very weak")
    }

    /// The same 40 in a file whose distances are in metres is out of range (−5…20 m): the
    /// import stores no tide height instead of a wrong one, and keeps the other fields.
    @Test func blueDiveXMLImportRefusesATideHeightOutOfRangeForTheFilesUnit() throws {
        let xml = BlueDiveXMLExporter.generateXML(for: diveWithNewFields(unit: "feet"))
            .replacingOccurrences(of: "<distanceFormat>feet</distanceFormat>",
                                  with: "<distanceFormat>meters</distanceFormat>")
        let parsed = try #require(BlueDiveXMLParser().parse(data: Data(xml.utf8))?.first)
        let imported = ContentView.makeDive(from: parsed)
        #expect(imported.tideHeight == nil)
        #expect(imported.tideState == "High")
        #expect(imported.current == "Very weak")
    }

    /// UDDF has no tide element: a UDDF round-trip loses the tide (documented), but keeps the
    /// current through its keyword.
    @Test func uddfImportKeepsTheCurrentButNoTide() throws {
        let uddf = BlueDiveUDDFExporter.generateUDDF(for: diveWithNewFields(unit: "meters"))
        #expect(!uddf.contains("<tide"))
        let parsed = try #require(UDDFXMLParser().parse(data: Data(uddf.utf8))?.first)
        let imported = ContentView.makeDive(from: parsed)
        #expect(imported.tideHeight == nil)
        #expect(imported.tideState == nil)
        #expect(imported.current == "Very weak")
    }

    // MARK: Number parsing

    @Test func unicodeMinusParses() {
        #expect(parseFlexibleDouble("\u{2212}0,42") == -0.42)
        #expect(parseFlexibleDouble("-0.42") == -0.42)
        #expect(parseFlexibleDouble("+0.42") == 0.42)
    }
}
