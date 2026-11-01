import Foundation
import Testing
@testable import BlueDive

/// Dive notes written with Markdown (blank lines, indentation, `*`, `#`, `|`, `<`, `&`, quotes)
/// through an export and a re-import: BlueDive XML and UDDF.
@MainActor
struct NotesRoundTripTests {

    private let note = """
    # Heading 1 – Morning dive

    Calm sea, light current.
    Second line.

    **Bold** & <b>html</b> "quotes" 'apos' ~~gone~~ `code`

    - Reef shark
      - Juvenile

    - First paragraph

      Second paragraph

    ```
    GF 30/85   PPO2 1.4
      indented  spacing kept
    ```

    | Tank | End |
    |:--|--:|
    | AL80 | 70 |

    > quote
    >
    >> nested
    """

    @Test func blueDiveXMLKeepsNotesExactly() throws {
        let dive = Dive()
        dive.notes = note
        let xml = BlueDiveXMLExporter.generateXML(for: dive)
        let parsed = try #require(BlueDiveXMLParser().parse(data: Data(xml.utf8))?.first)
        #expect(parsed.notes == note)
    }

    @Test func uddfKeepsNotesExactly() throws {
        let dive = Dive()
        dive.notes = note
        let uddf = BlueDiveUDDFExporter.generateUDDF(for: dive)
        let parsed = try #require(UDDFXMLParser().parse(data: Data(uddf.utf8))?.first)
        #expect(parsed.notes == note)
    }

    @Test func uddfWritesTheWholeNoteInOnePara() {
        // Subsurface's UDDF import reads only the first <para>.
        let dive = Dive()
        dive.notes = note
        let uddf = BlueDiveUDDFExporter.generateUDDF(for: dive)
        #expect(uddf.components(separatedBy: "<para>").count == 2)
        #expect(uddf.contains("&lt;b&gt;html&lt;/b&gt;"))
    }

    @Test func uddfWithoutNotesHasNoNotesElement() {
        #expect(!BlueDiveUDDFExporter.generateUDDF(for: Dive()).contains("<notes>"))
    }

    @Test func otherAppsPrettyPrintedParasStillImportTrimmedAndJoined() throws {
        // A file from another app (or an older BlueDive): several <para>, each indented inside
        // for layout. Imported as before: each trimmed, empty ones skipped, joined by line breaks.
        let dive = Dive()
        dive.notes = "PLACEHOLDER"
        let multiPara = """
        <notes>
                    <para>
                        First paragraph.
                    </para>
                    <para>   </para>
                    <para>Second paragraph.</para>
                  </notes>
        """
        let uddf = BlueDiveUDDFExporter.generateUDDF(for: dive)
            .replacingOccurrences(of: "<notes>\n            <para>PLACEHOLDER</para>\n          </notes>", with: multiPara)
        #expect(uddf.contains("First paragraph."))
        let parsed = try #require(UDDFXMLParser().parse(data: Data(uddf.utf8))?.first)
        #expect(parsed.notes == "First paragraph.\nSecond paragraph.")
    }
}
