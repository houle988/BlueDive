import Foundation
import Testing
@testable import BlueDive

/// The dive's current in UDDF: its six `<current>` keywords map one to one onto BlueDive's
/// `DiveConditionOptions.current` options, on import and on export. All values are made up.
@MainActor
struct UDDFCurrentTests {

    @Test func everyOptionHasAKeywordAndBack() {
        #expect(DiveConditionOptions.current.count == DiveConditionOptions.uddfCurrentKeywords.count)
        for option in DiveConditionOptions.current {
            let keyword = DiveConditionOptions.uddfCurrentKeyword(for: option)
            #expect(keyword != nil, "\(option)")
            #expect(keyword.map(DiveConditionOptions.current(fromUDDF:)) == option)
        }
        #expect(DiveConditionOptions.uddfCurrentKeyword(for: "Weak") == "mild-current")
        #expect(DiveConditionOptions.current(fromUDDF: "very-mild-current") == "Very weak")
    }

    @Test func unknownValuesAreKeptOnImportAndNotExported() {
        #expect(DiveConditionOptions.current(fromUDDF: "ripping") == "ripping")
        #expect(DiveConditionOptions.uddfCurrentKeyword(for: "ripping") == nil)
    }

    @Test func exportWritesTheKeywordAndImportReadsTheOption() throws {
        let dive = Dive(current: "Very weak")
        let uddf = BlueDiveUDDFExporter.generateUDDF(for: dive)
        #expect(uddf.contains("<current>very-mild-current</current>"))
        let parsed = try #require(UDDFXMLParser().parse(data: Data(uddf.utf8))?.first)
        #expect(parsed.current == "Very weak")
    }

    @Test func noCurrentIsNotExported() {
        #expect(!BlueDiveUDDFExporter.generateUDDF(for: Dive()).contains("<current>"))
        // A value outside the options has no UDDF keyword.
        #expect(!BlueDiveUDDFExporter.generateUDDF(for: Dive(current: "Ripping")).contains("<current>"))
    }
}
