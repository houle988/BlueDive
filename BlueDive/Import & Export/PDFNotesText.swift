import Foundation
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - PDF Notes Text

/// The dive notes as drawn by the PDF logbook (`PDFDiveLogbook`): plain text, or — when Settings →
/// Dive Profile → Format notes as Markdown is on — the same blocks `MarkdownText` shows on screen
/// (`MarkdownParser`), laid out with Core Text.
///
/// Core Text does not draw strikethrough, backgrounds, links or shapes, so those are marked with
/// the `pdf…` attribute keys below and drawn by `drawFrame` around the text: code block
/// backgrounds, quote bars, horizontal rules, the line under a table header, list bullets (drawn
/// shapes, as on screen), strikethrough and clickable link areas. Display only: the note itself is
/// never changed.
enum PDFNotesText {

    /// Colours of the notes card, from the PDF's palette.
    struct Palette {
        let text: CGColor
        let muted: CGColor
        /// Quoted text: grey, but darker than `muted` so it stays readable on paper.
        let quote: CGColor
        let accent: CGColor
        let rule: CGColor
        let codeBackground: CGColor
    }

    /// Spacing between lines, as the plain notes have always used.
    static let lineSpacing: CGFloat = 0.5

    // MARK: Building

    /// The note as plain text, exactly as the PDF has always drawn it.
    static func plain(_ text: String, size: CGFloat, color: CGColor) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font(.regular, size: size),
            .foregroundColor: platformColor(color),
            .paragraphStyle: paragraphStyle
        ])
    }

    /// The note formatted as Markdown at a base font `size`, for a text area `width` points wide
    /// (tables are laid out in columns when they fit it). Falls back to the plain text when the
    /// Markdown draws nothing, as on screen.
    static func markdown(_ source: String, size: CGFloat, width: CGFloat, palette: Palette) -> NSAttributedString {
        let blocks = MarkdownParser.blocks(from: source)
        guard !blocks.isEmpty else { return plain(source, size: size, color: palette.text) }

        let result = NSMutableAttributedString()
        let markerWidth = size * 1.8
        let quoteIndent = size * 1.2

        for (index, block) in blocks.enumerated() {
            let isFirst = index == 0
            let isLast = index == blocks.count - 1
            let leading = CGFloat(block.quoteDepth) * quoteIndent
                + CGFloat(max(block.listDepth - 1, 0)) * markerWidth
            let textIndent = leading + (block.listDepth > 0 ? markerWidth : 0)
            let color = block.quoteDepth > 0 ? palette.quote : palette.text

            func style(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = size * 0.35,
                       firstLine: CGFloat? = nil, head: CGFloat? = nil, tabs: [NSTextTab] = []) -> NSMutableParagraphStyle {
                let style = NSMutableParagraphStyle()
                style.lineSpacing = lineSpacing
                style.lineBreakMode = .byWordWrapping
                style.paragraphSpacingBefore = isFirst ? 0 : spacingBefore
                style.paragraphSpacing = spacingAfter
                style.firstLineHeadIndent = firstLine ?? textIndent
                style.headIndent = head ?? textIndent
                style.tabStops = tabs
                style.defaultTabInterval = size * 2
                return style
            }

            /// Appends one paragraph (with its paragraph break) and its block decorations.
            func append(_ paragraph: NSMutableAttributedString, style: NSParagraphStyle) {
                if !isLast { paragraph.append(NSAttributedString(string: "\n", attributes: [.font: font(.regular, size: size)])) }
                let range = NSRange(location: 0, length: paragraph.length)
                paragraph.addAttribute(.paragraphStyle, value: style, range: range)
                if block.quoteDepth > 0 {
                    paragraph.addAttribute(.pdfQuote, value: PDFQuote(depth: block.quoteDepth, indent: quoteIndent), range: range)
                }
                result.append(paragraph)
            }

            /// The list marker and a tab to the item's text, or nothing outside lists.
            func marker() -> NSMutableAttributedString {
                let marker = NSMutableAttributedString()
                switch block.marker {
                case .bullet(let level):
                    // A figure space holds the bullet's place; drawFrame draws the shape on it.
                    marker.append(NSAttributedString(string: "\u{2007}", attributes: [
                        .font: font(.regular, size: size), .pdfBullet: NSNumber(value: level)
                    ]))
                    marker.append(NSAttributedString(string: "\t", attributes: [.font: font(.regular, size: size)]))
                case .number(let number):
                    marker.append(NSAttributedString(string: number + "\t", attributes: [
                        .font: font(.regular, size: size), .foregroundColor: platformColor(palette.muted)
                    ]))
                case nil:
                    break
                }
                return marker
            }
            let markerTabs = block.marker == nil ? [] : [NSTextTab(textAlignment: .left, location: textIndent)]
            let markerFirstLine = block.marker == nil ? textIndent : leading

            switch block.kind {
            case .heading(let level, let text):
                let scale: CGFloat = level == 1 ? 1.4 : (level == 2 ? 1.25 : (level == 3 ? 1.1 : 1.0))
                let paragraph = marker()
                paragraph.append(inline(text, size: size * scale, bold: true, color: color, palette: palette))
                append(paragraph, style: style(spacingBefore: size * 0.5, spacingAfter: size * 0.25,
                                               firstLine: markerFirstLine, tabs: markerTabs))

            case .paragraph(let text):
                let paragraph = marker()
                paragraph.append(inline(text, size: size, bold: false, color: color, palette: palette))
                append(paragraph, style: style(firstLine: markerFirstLine, tabs: markerTabs))

            case .code(let code):
                let padding = size * 0.6
                let paragraph = NSMutableAttributedString(string: code.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: [
                    .font: font(.code, size: size * 0.9),
                    .foregroundColor: platformColor(color),
                    .pdfCode: NSNumber(value: index)
                ])
                append(paragraph, style: style(spacingBefore: size * 0.4, spacingAfter: size * 0.7,
                                               firstLine: textIndent + padding, head: textIndent + padding))

            case .rule:
                let paragraph = NSMutableAttributedString(string: "\u{00A0}", attributes: [
                    .font: font(.regular, size: size), .pdfRule: true
                ])
                append(paragraph, style: style(spacingBefore: size * 0.2, spacingAfter: size * 0.5))

            case .table(let table):
                appendTable(table, to: result, size: size, available: width - textIndent, indent: textIndent,
                            isFirst: isFirst, isLast: isLast, quote: block.quoteDepth > 0 ? PDFQuote(depth: block.quoteDepth, indent: quoteIndent) : nil,
                            color: color, palette: palette)
            }
        }
        return result
    }

    /// A table: columns positioned with tab stops (aligned as in the delimiter row) when the
    /// table fits the width, else each row as one wrapped line with its cells separated by " · ".
    private static func appendTable(_ table: MarkdownTable, to result: NSMutableAttributedString, size: CGFloat,
                                    available: CGFloat, indent: CGFloat, isFirst: Bool, isLast: Bool,
                                    quote: PDFQuote?, color: CGColor, palette: Palette) {
        let header = table.header.map { inline($0, size: size, bold: true, color: color, palette: palette) }
        let rows = table.rows.map { $0.map { inline($0, size: size, bold: false, color: color, palette: palette) } }
        let allRows = [header] + rows
        let columnCount = header.count
        let gap = size * 1.6

        var widths = Array(repeating: CGFloat(0), count: columnCount)
        for row in allRows {
            for (column, cell) in row.enumerated() where column < columnCount {
                widths[column] = max(widths[column], lineWidth(cell))
            }
        }
        let totalWidth = widths.reduce(0, +) + gap * CGFloat(max(columnCount - 1, 0))
        let fits = totalWidth <= available

        var tabs: [NSTextTab] = []
        if fits {
            var start = indent
            for column in 0..<columnCount {
                let alignment = column < table.alignments.count ? table.alignments[column] : .left
                switch alignment {
                case .center: tabs.append(NSTextTab(textAlignment: .center, location: start + widths[column] / 2))
                case .right:  tabs.append(NSTextTab(textAlignment: .right, location: start + widths[column]))
                default:
                    // A left-aligned first column starts at the indent itself; no tab needed.
                    if column > 0 { tabs.append(NSTextTab(textAlignment: .left, location: start)) }
                }
                start += widths[column] + gap
            }
        }
        let firstColumnNeedsTab = fits && columnCount > 0
            && (table.alignments.first == .center || table.alignments.first == .right)

        for (rowIndex, row) in allRows.enumerated() {
            let isHeader = rowIndex == 0
            let isLastRow = rowIndex == allRows.count - 1
            let paragraph = NSMutableAttributedString()
            let separatorAttributes: [NSAttributedString.Key: Any] = [
                .font: font(.regular, size: size), .foregroundColor: platformColor(palette.muted)
            ]
            for (column, cell) in row.enumerated() {
                if fits {
                    if column > 0 || firstColumnNeedsTab { paragraph.append(NSAttributedString(string: "\t", attributes: separatorAttributes)) }
                } else if column > 0 {
                    paragraph.append(NSAttributedString(string: " · ", attributes: separatorAttributes))
                }
                let text = NSMutableAttributedString(attributedString: cell)
                text.mutableString.replaceOccurrences(of: "\t", with: " ", range: NSRange(location: 0, length: text.length))
                paragraph.append(text)
            }
            if paragraph.length == 0 { paragraph.append(NSAttributedString(string: "\u{00A0}", attributes: separatorAttributes)) }
            if !(isLast && isLastRow) {
                paragraph.append(NSAttributedString(string: "\n", attributes: [.font: font(.regular, size: size)]))
            }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.lineBreakMode = .byWordWrapping
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.tabStops = tabs
            style.paragraphSpacingBefore = (isHeader && !isFirst) ? size * 0.4 : 0
            style.paragraphSpacing = isHeader ? size * 0.45 : (isLastRow ? size * 0.7 : size * 0.2)
            let range = NSRange(location: 0, length: paragraph.length)
            paragraph.addAttribute(.paragraphStyle, value: style, range: range)
            if isHeader && fits {
                paragraph.addAttribute(.pdfTableHeader, value: NSNumber(value: Double(totalWidth)), range: range)
            }
            if let quote { paragraph.addAttribute(.pdfQuote, value: quote, range: range) }
            result.append(paragraph)
        }
    }

    /// Inline styles of one block: bold, italic, inline code, strikethrough and links.
    private static func inline(_ text: AttributedString, size: CGFloat, bold: Bool, color: CGColor, palette: Palette) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            // A typed line break stays inside the paragraph (no paragraph spacing).
            let string = String(text[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
            let intent = run.inlinePresentationIntent ?? []
            let isBold = bold || intent.contains(.stronglyEmphasized)
            let isItalic = intent.contains(.emphasized)
            let face: Face
            if intent.contains(.code) {
                face = .code
            } else if isBold && isItalic {
                face = .boldItalic
            } else if isBold {
                face = .bold
            } else if isItalic {
                face = .italic
            } else {
                face = .regular
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(face, size: face == .code ? size * 0.9 : size),
                .foregroundColor: platformColor(color)
            ]
            if intent.contains(.strikethrough) { attributes[.pdfStrikethrough] = true }
            if let url = run.link {
                attributes[.foregroundColor] = platformColor(palette.accent)
                attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = NSNumber(value: CTUnderlineStyle.single.rawValue)
                attributes[.pdfLink] = url
            }
            result.append(NSAttributedString(string: string, attributes: attributes))
        }
        return result
    }

    // MARK: Measuring and Drawing

    /// Height the text from `location` to the end needs at `width`, rounded up so the last line
    /// is never dropped when the frame is drawn at exactly this height.
    static func height(_ text: NSAttributedString, from location: Int, width: CGFloat) -> CGFloat {
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: location, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
        return ceil(size.height) + 1
    }

    /// Where the text from `location` would stop in a `width` × `height` area, without drawing it
    /// (`location` itself when not even one line fits).
    static func fittingEnd(_ text: NSAttributedString, from location: Int, width: CGFloat, height: CGFloat) -> Int {
        guard height > 0 else { return location }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        return visible.location + visible.length
    }

    /// Draws as much of the text from `location` as fits in `rect` and returns where the next
    /// page continues (`text.length` when everything was drawn). Core Text places only whole
    /// lines, so a line is never cut between two pages.
    @discardableResult
    static func drawFrame(_ text: NSAttributedString, from location: Int, in rect: CGRect,
                          ctx: CGContext, palette: Palette) -> Int {
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0),
                                             CGPath(rect: rect, transform: nil), nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        struct LineBox {
            let line: CTLine
            let origin: CGPoint
            let ascent: CGFloat
            let descent: CGFloat
            let attributes: [NSAttributedString.Key: Any]
        }
        let boxes: [LineBox] = zip(lines, origins).map { line, origin in
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let range = CTLineGetStringRange(line)
            let attributes = range.location < text.length ? text.attributes(at: range.location, effectiveRange: nil) : [:]
            return LineBox(line: line, origin: CGPoint(x: rect.minX + origin.x, y: rect.minY + origin.y),
                           ascent: ascent, descent: descent, attributes: attributes)
        }

        // Code block backgrounds, behind the text: one rounded box per block on this page.
        var codeRects: [Int: CGRect] = [:]
        for box in boxes {
            guard let id = (box.attributes[.pdfCode] as? NSNumber)?.intValue else { continue }
            let lineRect = CGRect(x: box.origin.x, y: box.origin.y - box.descent,
                                  width: rect.maxX - box.origin.x, height: box.ascent + box.descent)
            codeRects[id] = codeRects[id].map { $0.union(lineRect) } ?? lineRect
        }
        ctx.saveGState()
        ctx.setFillColor(palette.codeBackground)
        for codeRect in codeRects.values {
            let box = CGRect(x: codeRect.minX - 4, y: codeRect.minY - 2,
                             width: codeRect.width + 4, height: codeRect.height + 4)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
        }
        ctx.restoreGState()

        ctx.saveGState()
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()

        ctx.saveGState()
        for box in boxes {
            let top = box.origin.y + box.ascent + 1
            let bottom = box.origin.y - box.descent - 1

            // Quote bars, one per quote level.
            if let quote = box.attributes[.pdfQuote] as? PDFQuote {
                ctx.setFillColor(palette.rule)
                for level in 0..<quote.depth {
                    ctx.fill(CGRect(x: rect.minX + CGFloat(level) * quote.indent, y: bottom, width: 1.2, height: top - bottom))
                }
            }
            // Horizontal rule across the text area.
            if box.attributes[.pdfRule] != nil {
                ctx.setFillColor(palette.rule)
                ctx.fill(CGRect(x: box.origin.x, y: box.origin.y + box.ascent * 0.3, width: rect.maxX - box.origin.x, height: 0.5))
            }
            // Line under a table header row, as wide as the table.
            if let tableWidth = (box.attributes[.pdfTableHeader] as? NSNumber)?.doubleValue {
                ctx.setFillColor(palette.rule)
                ctx.fill(CGRect(x: box.origin.x, y: box.origin.y - box.descent - 1.2, width: CGFloat(tableWidth), height: 0.5))
            }

            // Inline decorations, run by run.
            for run in CTLineGetGlyphRuns(box.line) as? [CTRun] ?? [] {
                let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
                let runRange = CTRunGetStringRange(run)
                let startX = box.origin.x + CTLineGetOffsetForStringIndex(box.line, runRange.location, nil)
                let endX = box.origin.x + CTLineGetOffsetForStringIndex(box.line, runRange.location + runRange.length, nil)
                // Helvetica Neue's x-height is about 0.54 of its ascent.
                let xHeight = box.ascent * 0.54

                if let level = (runAttributes[.pdfBullet] as? NSNumber)?.intValue {
                    let side = box.ascent * 0.38
                    let bullet = CGRect(x: startX, y: box.origin.y + xHeight / 2 - side / 2, width: side, height: side)
                    ctx.setFillColor(palette.muted)
                    ctx.setStrokeColor(palette.muted)
                    switch level {
                    case 1:
                        ctx.fillEllipse(in: bullet)
                    case 2:
                        ctx.setLineWidth(max(side * 0.18, 0.4))
                        ctx.strokeEllipse(in: bullet.insetBy(dx: side * 0.09, dy: side * 0.09))
                    default:
                        ctx.fill(bullet.insetBy(dx: side * 0.08, dy: side * 0.08))
                    }
                }
                if runAttributes[.pdfStrikethrough] != nil {
                    ctx.setFillColor(palette.text)
                    ctx.fill(CGRect(x: startX, y: box.origin.y + xHeight * 0.5, width: endX - startX, height: 0.45))
                }
                if let url = runAttributes[.pdfLink] as? URL {
                    let linkRect = CGRect(x: startX, y: box.origin.y - box.descent,
                                          width: endX - startX, height: box.ascent + box.descent)
                    ctx.setURL(url as CFURL, for: linkRect)
                }
            }
        }
        ctx.restoreGState()

        return visible.location + visible.length
    }

    // MARK: Fonts and Colours

    private enum Face { case regular, bold, italic, boldItalic, code }

    /// The PDF's Helvetica Neue family, and Menlo for code.
    private static func font(_ face: Face, size: CGFloat) -> CTFont {
        let name: String
        switch face {
        case .regular:    name = "HelveticaNeue"
        case .bold:       name = "HelveticaNeue-Bold"
        case .italic:     name = "HelveticaNeue-Italic"
        case .boldItalic: name = "HelveticaNeue-BoldItalic"
        case .code:       name = "Menlo-Regular"
        }
        return CTFontCreateWithName(name as CFString, size, nil)
    }

    private static func lineWidth(_ text: NSAttributedString) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text as CFAttributedString), nil, nil, nil))
    }

    private static func platformColor(_ cgColor: CGColor) -> Any {
        #if os(macOS)
        return NSColor(cgColor: cgColor) ?? NSColor.black
        #else
        return UIColor(cgColor: cgColor)
        #endif
    }
}

/// A quote's depth and the indent of each level, for drawing its bars.
final class PDFQuote: NSObject {
    let depth: Int
    let indent: CGFloat

    init(depth: Int, indent: CGFloat) {
        self.depth = depth
        self.indent = indent
    }
}

extension NSAttributedString.Key {
    /// Markers read by `PDFNotesText.drawFrame` to draw what Core Text does not.
    static let pdfStrikethrough = NSAttributedString.Key("BlueDivePDFStrikethrough")
    static let pdfLink = NSAttributedString.Key("BlueDivePDFLink")
    static let pdfBullet = NSAttributedString.Key("BlueDivePDFBullet")
    static let pdfCode = NSAttributedString.Key("BlueDivePDFCode")
    static let pdfQuote = NSAttributedString.Key("BlueDivePDFQuote")
    static let pdfRule = NSAttributedString.Key("BlueDivePDFRule")
    static let pdfTableHeader = NSAttributedString.Key("BlueDivePDFTableHeader")
}
