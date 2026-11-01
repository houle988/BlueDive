import Foundation
import Testing
@testable import BlueDive

/// `MarkdownParser.blocks(from:)`, the blocks `MarkdownText` lays out for dive notes when
/// Settings → Dive Profile → Format notes as Markdown is on: headings, paragraphs (typed line
/// breaks kept), lists, quotes, code blocks, rules, tables and inline styles.
@MainActor
struct MarkdownTextTests {

    // MARK: Helpers

    private func blocks(_ source: String) -> [MarkdownBlock] {
        MarkdownParser.blocks(from: source)
    }

    private func plain(_ text: AttributedString) -> String {
        String(text.characters)
    }

    private func paragraphText(_ block: MarkdownBlock) -> String? {
        if case .paragraph(let text) = block.kind { return plain(text) }
        return nil
    }

    private func heading(_ block: MarkdownBlock) -> (level: Int, text: String)? {
        if case .heading(let level, let text) = block.kind { return (level, plain(text)) }
        return nil
    }

    private func code(_ block: MarkdownBlock) -> String? {
        if case .code(let code) = block.kind { return code }
        return nil
    }

    private func table(_ block: MarkdownBlock) -> MarkdownTable? {
        if case .table(let table) = block.kind { return table }
        return nil
    }

    private func isRule(_ block: MarkdownBlock) -> Bool {
        if case .rule = block.kind { return true }
        return false
    }

    // MARK: Paragraphs

    @Test func emptyNoteHasNoBlocks() {
        #expect(blocks("").isEmpty)
    }

    @Test func plainNoteIsOneParagraph() throws {
        let result = blocks("Nice dive with a turtle.")
        try #require(result.count == 1)
        #expect(paragraphText(result[0]) == "Nice dive with a turtle.")
        #expect(result[0].listDepth == 0)
        #expect(result[0].quoteDepth == 0)
        #expect(result[0].marker == nil)
    }

    @Test func typedLineBreaksAreKept() throws {
        // Plain Markdown would join these into "Line one line two".
        let result = blocks("Line one\nline two\nline three")
        try #require(result.count == 1)
        #expect(paragraphText(result[0]) == "Line one\nline two\nline three")
    }

    @Test func blankLineSeparatesParagraphs() {
        let result = blocks("First\n\nSecond")
        #expect(result.compactMap(paragraphText) == ["First", "Second"])
    }

    @Test func blockIdentifiersAreUnique() {
        let result = blocks("# A\n\nText\n\n- one\n- two\n\n---\n\n```\ncode\n```")
        #expect(Set(result.map(\.id)).count == result.count)
    }

    @Test func htmlIsShownAsTyped() throws {
        let result = blocks("<b>bold</b> & 5 < 6")
        try #require(result.count == 1)
        #expect(paragraphText(result[0]) == "<b>bold</b> & 5 < 6")
    }

    // MARK: Inline styles

    @Test func inlineStylesAreParsed() throws {
        let result = blocks("**bold** *italic* ~~gone~~ `code`")
        try #require(result.count == 1)
        guard case .paragraph(let text) = result[0].kind else {
            Issue.record("Expected a paragraph")
            return
        }
        #expect(plain(text) == "bold italic gone code")
        let intents = text.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains(.stronglyEmphasized))
        #expect(intents.contains(.emphasized))
        #expect(intents.contains(.strikethrough))
        #expect(intents.contains(.code))
    }

    @Test func linksKeepTheirURL() throws {
        let result = blocks("See [reef map](https://example.com/reef)")
        try #require(result.count == 1)
        guard case .paragraph(let text) = result[0].kind else {
            Issue.record("Expected a paragraph")
            return
        }
        #expect(plain(text) == "See reef map")
        #expect(text.runs.compactMap(\.link) == [URL(string: "https://example.com/reef")!])
    }

    // MARK: Headings

    @Test func atxHeadingsKeepTheirLevel() {
        let result = blocks("# One\n## Two\n### Three\n#### Four")
        let headings = result.compactMap(heading)
        #expect(headings.map(\.level) == [1, 2, 3, 4])
        #expect(headings.map(\.text) == ["One", "Two", "Three", "Four"])
    }

    @Test func headingThenParagraph() throws {
        let result = blocks("# Conditions\nVisibility 20 m")
        try #require(result.count == 2)
        #expect(heading(result[0])?.text == "Conditions")
        #expect(paragraphText(result[1]) == "Visibility 20 m")
    }

    @Test func lineFollowedByDashesIsASetextHeading() throws {
        // Standard Markdown (as on GitHub): "---" under a line makes it a heading, not a rule.
        let result = blocks("Title\n---")
        try #require(result.count == 1)
        #expect(heading(result[0])?.level == 2)
        #expect(heading(result[0])?.text == "Title")
    }

    // MARK: Lists

    @Test func bulletListItemsGetBulletMarkers() {
        let result = blocks("- Turtle\n- Shark\n* Ray")
        #expect(result.compactMap(paragraphText) == ["Turtle", "Shark", "Ray"])
        #expect(result.map(\.marker) == [.bullet(level: 1), .bullet(level: 1), .bullet(level: 1)])
        #expect(result.allSatisfy { $0.listDepth == 1 })
    }

    @Test func orderedListItemsGetTheirNumbers() {
        let result = blocks("1. Descend\n2. Swim north\n3. Ascend")
        #expect(result.compactMap(paragraphText) == ["Descend", "Swim north", "Ascend"])
        #expect(result.map(\.marker) == [.number("1."), .number("2."), .number("3.")])
    }

    @Test func orderedListKeepsItsStartNumber() {
        let result = blocks("4. Fourth\n5. Fifth")
        #expect(result.map(\.marker) == [.number("4."), .number("5.")])
    }

    @Test func nestedListsAreIndentedWithTheirOwnMarkers() throws {
        let result = blocks("- Gear\n  - Fins\n  - Mask\n- Gas\n  1. Air\n  2. Nitrox")
        try #require(result.count == 6)
        #expect(result.map(\.listDepth) == [1, 2, 2, 1, 2, 2])
        #expect(result.map(\.marker) == [
            .bullet(level: 1), .bullet(level: 2), .bullet(level: 2),
            .bullet(level: 1), .number("1."), .number("2."),
        ])
    }

    @Test func bulletLevelFollowsNestingDepth() throws {
        // Level 1 disc, 2 circle, 3 and deeper square (drawn by MarkdownText).
        let result = blocks("- One\n  - Two\n    - Three\n      - Four")
        try #require(result.count == 4)
        #expect(result.map(\.listDepth) == [1, 2, 3, 4])
        #expect(result.map(\.marker) == [.bullet(level: 1), .bullet(level: 2), .bullet(level: 3), .bullet(level: 4)])
    }

    @Test func bulletInsideANumberedListIsNested() throws {
        // As in browsers, every enclosing list counts, numbered or not.
        let result = blocks("1. Gas\n   - Air")
        try #require(result.count == 2)
        #expect(result.map(\.marker) == [.number("1."), .bullet(level: 2)])
    }

    @Test func secondParagraphOfAnItemHasNoMarker() throws {
        let result = blocks("- First paragraph\n\n  Second paragraph\n- Next item")
        try #require(result.count == 3)
        #expect(result.compactMap(paragraphText) == ["First paragraph", "Second paragraph", "Next item"])
        #expect(result.map(\.marker) == [.bullet(level: 1), nil, .bullet(level: 1)])
        #expect(result.map(\.listDepth) == [1, 1, 1])
    }

    // MARK: Quotes

    @Test func quotesCountTheirDepth() throws {
        let result = blocks("> Guide said\n>\n>> nested\n\nAfter")
        try #require(result.count == 3)
        #expect(result.map(\.quoteDepth) == [1, 2, 0])
        #expect(paragraphText(result[0]) == "Guide said")
        #expect(paragraphText(result[1]) == "nested")
    }

    @Test func listInsideAQuote() throws {
        let result = blocks("> - one\n> - two")
        try #require(result.count == 2)
        #expect(result.allSatisfy { $0.quoteDepth == 1 && $0.listDepth == 1 })
        #expect(result.map(\.marker) == [.bullet(level: 1), .bullet(level: 1)])
    }

    // MARK: Code blocks and rules

    @Test func fencedCodeBlockIsKeptVerbatim() throws {
        // No hard-break spaces are added inside the fence, and the final newline is dropped.
        let result = blocks("```\nlet depth = 18.5\n  indented  x\n```")
        try #require(result.count == 1)
        #expect(code(result[0]) == "let depth = 18.5\n  indented  x")
    }

    @Test func tildeFenceIsACodeBlock() throws {
        let result = blocks("~~~\nraw *text*\n~~~")
        try #require(result.count == 1)
        #expect(code(result[0]) == "raw *text*")
    }

    @Test func textAfterACodeBlockKeepsItsLineBreaks() throws {
        let result = blocks("```\ncode\n```\nafter one\nafter two")
        try #require(result.count == 2)
        #expect(code(result[0]) == "code")
        #expect(paragraphText(result[1]) == "after one\nafter two")
    }

    @Test func otherFenceCharacterInsideACodeBlockStaysCode() throws {
        // A "~~~" line does not close a "```" block, so no hard-break spaces are added after it.
        let result = blocks("```\nbefore\n~~~\nafter\n```\nText")
        try #require(result.count == 2)
        #expect(code(result[0]) == "before\n~~~\nafter")
        #expect(paragraphText(result[1]) == "Text")
        #expect(MarkdownParser.keepingLineBreaks("```\n~~~\ncode\n```") == "```\n~~~\ncode\n```")
    }

    @Test func lineBreakSpacesAreAddedOnlyOutsideFences() {
        #expect(MarkdownParser.keepingLineBreaks("a\n\nb") == "a  \n\nb  ")
        #expect(MarkdownParser.keepingLineBreaks("~~~\nx\n~~~\ny") == "~~~\nx\n~~~\ny  ")
    }

    @Test func noteThatDrawsNothingHasNoBlocks() {
        // A lone link reference definition draws nothing; MarkdownText then shows the note as typed.
        #expect(blocks("[reef]: https://example.com/reef").isEmpty)
    }

    @Test func onlyTextBlocksAreReadWithTheirListMarker() throws {
        let result = blocks("- Item\n- ```\n  code\n  ```")
        try #require(result.count == 2)
        #expect(result[0].isText)
        #expect(!result[1].isText)
    }

    @Test func thematicBreakIsARule() throws {
        let result = blocks("Above\n\n---\n\nBelow")
        try #require(result.count == 3)
        #expect(isRule(result[1]))
        #expect(paragraphText(result[0]) == "Above")
        #expect(paragraphText(result[2]) == "Below")
    }

    // MARK: Tables

    @Test func tableCollectsHeaderRowsAndAlignments() throws {
        let source = """
        | Tank | Start | End |
        |:-----|:-----:|----:|
        | AL80 | 200 | 50 |
        | Stage | 210 | 120 |
        """
        let result = blocks(source)
        try #require(result.count == 1)
        let parsed = try #require(table(result[0]))
        #expect(parsed.alignments == [.left, .center, .right])
        #expect(parsed.header.map(plain) == ["Tank", "Start", "End"])
        #expect(parsed.rows.map { $0.map(plain) } == [["AL80", "200", "50"], ["Stage", "210", "120"]])
    }

    @Test func emptyTableCellsStayEmpty() throws {
        let source = """
        | A | B |
        |---|---|
        |   | y |
        | x |   |
        """
        let parsed = try #require(blocks(source).first.flatMap(table))
        #expect(parsed.rows.map { $0.map(plain) } == [["", "y"], ["x", ""]])
    }

    @Test func tableCellsKeepInlineStyles() throws {
        let source = """
        | Species |
        |---|
        | **Turtle** |
        """
        let parsed = try #require(blocks(source).first.flatMap(table))
        let cell = try #require(parsed.rows.first?.first)
        #expect(plain(cell) == "Turtle")
        #expect(cell.runs.compactMap(\.inlinePresentationIntent).contains(.stronglyEmphasized))
    }

    @Test func twoTablesAreSeparateBlocks() throws {
        let source = """
        | A |
        |---|
        | 1 |

        Between

        | B |
        |---|
        | 2 |
        """
        let result = blocks(source)
        try #require(result.count == 3)
        #expect(table(result[0])?.header.map(plain) == ["A"])
        #expect(paragraphText(result[1]) == "Between")
        #expect(table(result[2])?.header.map(plain) == ["B"])
    }

    // MARK: Whole note

    @Test func typicalDiveNote() {
        let source = """
        # Morning dive
        Calm sea, **great** visibility.

        ## Sightings
        - Green turtle
        - Reef shark

        | Gas | Start | End |
        |---|--:|--:|
        | EAN32 | 200 | 70 |

        > Guide: watch the current at the point.
        """
        let result = blocks(source)
        #expect(result.count == 7)
        #expect(heading(result[0])?.text == "Morning dive")
        #expect(paragraphText(result[1]) == "Calm sea, great visibility.")
        #expect(heading(result[2])?.level == 2)
        #expect(result[3].marker == .bullet(level: 1))
        #expect(result[4].marker == .bullet(level: 1))
        #expect(table(result[5])?.rows.first?.map(plain) == ["EAN32", "200", "70"])
        #expect(result[6].quoteDepth == 1)
    }
}
