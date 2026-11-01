import Foundation
import PDFKit
import Testing
@testable import BlueDive

/// The PDF logbook's notes (`PDFNotesText`, `PDFDiveLogbook`): Markdown formatting when Settings →
/// Dive Profile → Format notes as Markdown is on, plain text when it is off, and notes too long
/// for the first page continuing on further pages without losing a line.
@MainActor
@Suite(.serialized)
struct PDFNotesTests {

    // MARK: Helpers

    private let palette = PDFNotesText.Palette(
        text: CGColor(gray: 0, alpha: 1), muted: CGColor(gray: 0.5, alpha: 1), quote: CGColor(gray: 0.4, alpha: 1),
        accent: CGColor(red: 0, green: 0.5, blue: 0.7, alpha: 1), rule: CGColor(gray: 0.8, alpha: 1),
        codeBackground: CGColor(gray: 0.9, alpha: 1)
    )

    /// Generates the PDF of a dive with these notes, with the Markdown setting as given, and
    /// returns the text of each page.
    private func pages(notes: String, markdown: Bool) throws -> [String] {
        let prefs = UserPreferences.shared
        let saved = prefs.formatNotesAsMarkdown
        prefs.formatNotesAsMarkdown = markdown
        defer { prefs.formatNotesAsMarkdown = saved }

        let dive = Dive()
        dive.notes = notes
        let data = try #require(PDFDiveLogbook.generatePDF(for: dive, allDives: [dive]))
        let document = try #require(PDFDocument(data: data))
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    private func numberedLines(_ count: Int) -> String {
        (1...count).map { "Line \($0) of the dive notes" }.joined(separator: "\n")
    }

    // MARK: Pages

    @Test func shortNoteStaysOnOnePage() throws {
        let result = try pages(notes: "Calm sea, light current.", markdown: false)
        #expect(result.count == 1)
        #expect(result[0].contains("Calm sea, light current."))
    }

    @Test func emptyNotesShowNoNotes() throws {
        let result = try pages(notes: "", markdown: true)
        #expect(result.count == 1)
    }

    @Test func longPlainNoteContinuesWithoutLosingALine() throws {
        let count = 400
        let result = try pages(notes: numberedLines(count), markdown: false)
        #expect(result.count >= 2)
        #expect(result[1].contains(NSLocalizedString("NOTES (CONTINUED)", bundle: Bundle.forAppLanguage(), comment: "")))

        // Every line appears exactly once across the pages, in order.
        let all = result.joined(separator: "\n")
        var searchStart = all.startIndex
        for line in 1...count {
            let needle = "Line \(line) of the dive notes"
            let found = try #require(all.range(of: needle, range: searchStart..<all.endIndex), "missing \(needle)")
            searchStart = found.upperBound
        }
    }

    @Test func longMarkdownNoteContinuesWithoutLosingAnItem() throws {
        let count = 300
        let notes = "# Sightings\n" + (1...count).map { "- Item \($0)" }.joined(separator: "\n")
        let result = try pages(notes: notes, markdown: true)
        #expect(result.count >= 2)
        let all = result.joined(separator: "\n")
        for item in [1, count / 2, count] {
            #expect(all.contains("Item \(item)"))
        }
        #expect(!all.contains("- Item"))
    }

    @Test func noteThatFitsWhenShrunkStaysOnOnePage() throws {
        // About as long as a page holds at the smallest size: shrunk, not split, as before.
        let result = try pages(notes: numberedLines(25), markdown: false)
        #expect(result.count == 1)
        #expect(result[0].contains("Line 25 of the dive notes"))
    }

    // MARK: Markdown in the PDF

    @Test func markdownSyntaxIsNotPrintedWhenTheSettingIsOn() throws {
        let notes = "# Morning dive\n**Bold** and *italic* and ~~gone~~ and `code`\n\n- Turtle\n\n| Gas | End |\n|---|--:|\n| EAN32 | 70 |"
        let text = try pages(notes: notes, markdown: true).joined()
        #expect(text.contains("Morning dive"))
        #expect(text.contains("Turtle"))
        #expect(text.contains("EAN32"))
        for syntax in ["# Morning", "**", "~~", "`", "- Turtle", "|---"] {
            #expect(!text.contains(syntax), "printed \(syntax)")
        }
    }

    @Test func markdownSyntaxIsPrintedAsTypedWhenTheSettingIsOff() throws {
        let text = try pages(notes: "# Morning dive\n**Bold**", markdown: false).joined()
        #expect(text.contains("# Morning dive"))
        #expect(text.contains("**Bold**"))
    }

    // MARK: Formatted text

    @Test func bulletsAreMarkedForDrawingByLevel() {
        let text = PDFNotesText.markdown("- One\n  - Two\n    - Three", size: 7.5, width: 500, palette: palette)
        var levels: [Int] = []
        text.enumerateAttribute(.pdfBullet, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let level = (value as? NSNumber)?.intValue { levels.append(level) }
        }
        #expect(levels == [1, 2, 3])
    }

    @Test func tableThatFitsUsesTabStopsAndAHeaderLine() throws {
        let text = PDFNotesText.markdown("| Tank | End |\n|:--|--:|\n| AL80 | 70 |", size: 7.5, width: 500, palette: palette)
        #expect(text.string.contains("Tank\tEnd"))
        #expect(!text.string.contains(" · "))
        let style = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.tabStops.map(\.alignment) == [.right])
        #expect(text.attribute(.pdfTableHeader, at: 0, effectiveRange: nil) != nil)
    }

    @Test func tableTooWideFallsBackToOneLinePerRow() {
        let source = "| A long first column | Another long column | And a third one |\n|---|---|---|\n| x | y | z |"
        let text = PDFNotesText.markdown(source, size: 7.5, width: 60, palette: palette)
        #expect(text.string.contains("A long first column · Another long column · And a third one"))
        #expect(text.string.contains("x · y · z"))
    }

    @Test func inlineDecorationsAreMarked() {
        let text = PDFNotesText.markdown("~~gone~~ [map](https://example.com)", size: 7.5, width: 500, palette: palette)
        var strike = false
        var link: URL?
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            if attributes[.pdfStrikethrough] != nil { strike = true }
            if let url = attributes[.pdfLink] as? URL { link = url }
        }
        #expect(strike)
        #expect(link == URL(string: "https://example.com"))
    }

    @Test func typedLineBreaksStayInTheParagraph() {
        // Line separators, not paragraph breaks, so no paragraph spacing between typed lines.
        let text = PDFNotesText.markdown("one\ntwo", size: 7.5, width: 500, palette: palette)
        #expect(text.string == "one\u{2028}two")
    }

    @Test func fittingEndFindsWhetherAnyLineFits() {
        // Page 1 draws no notes card when not even one line fits the room left.
        let text = PDFNotesText.plain("one\ntwo\nthree", size: 7.5, color: palette.text)
        #expect(PDFNotesText.fittingEnd(text, from: 0, width: 400, height: 4) == 0)
        #expect(PDFNotesText.fittingEnd(text, from: 0, width: 400, height: 1000) == text.length)
        let oneLine = PDFNotesText.fittingEnd(text, from: 0, width: 400, height: 10)
        #expect(oneLine > 0 && oneLine < text.length)
    }

    @Test func plainTextIsUnchanged() throws {
        let text = PDFNotesText.plain("a\nb", size: 7.5, color: palette.text)
        #expect(text.string == "a\nb")
        let style = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.lineSpacing == 0.5)
    }
}
