import SwiftUI

// MARK: - Markdown Text

/// Shows a plain-text note formatted as Markdown (Settings → Dive Profile → Format notes as
/// Markdown, `UserPreferences.formatNotesAsMarkdown`): headings, bold, italic, strikethrough,
/// inline code, links, bullet and numbered lists, quotes, code blocks, horizontal rules and tables.
///
/// Display only: the note is stored, searched and exported exactly as typed. Parsing uses
/// Foundation's Markdown parser (`AttributedString(markdown:)`, full syntax); SwiftUI `Text` draws
/// only inline styles, so the blocks it reports through `presentationIntent` are laid out here.
/// Every line break the user typed is kept (as in GitHub comments), so notes typed line by line
/// read as they did in plain text. HTML is shown as typed.
struct MarkdownText: View {
    let source: String

    /// Width of a list item's marker column (a bullet, "12."), scaled with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 24
    /// Size of a drawn bullet, and how far its bottom sits above the text baseline so it is
    /// centred on the x-height like a typed "•".
    @ScaledMetric(relativeTo: .body) private var bulletSize: CGFloat = 6
    @ScaledMetric(relativeTo: .body) private var bulletLift: CGFloat = 1.5

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        let blocks = MarkdownBlockCache.blocks(for: source)
        VStack(alignment: .leading, spacing: 8) {
            if blocks.isEmpty {
                // Markdown that draws nothing (e.g. only a link reference definition): show the
                // note as typed rather than an empty card.
                Text(verbatim: source)
                    .font(.body)
            } else {
                ForEach(blocks) { block in
                    blockView(block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Blocks

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        quoted(listIndented(content(block), block: block), depth: block.quoteDepth)
    }

    @ViewBuilder
    private func content(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(text)
                .font(Self.headingFont(level: level))
                .padding(.top, level <= 2 ? 4 : 0)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(text)
                .font(.body)
        case .code(let code):
            Text(verbatim: code)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        case .rule:
            Divider()
                .padding(.vertical, 4)
                .accessibilityHidden(true)
        case .table(let table):
            // Extra space so consecutive tables, or a table next to a heading, read apart.
            MarkdownTableView(table: table)
                .padding(.vertical, 4)
        }
    }

    /// Lays a block inside list items out after its marker column: the item's first block shows
    /// the marker, its later blocks (a second paragraph, a nested table) line up with that text.
    /// VoiceOver reads an item's text paragraph with its marker as one element ("Bullet, Green
    /// turtle", "1., Descend"); tables and code blocks keep their own elements.
    @ViewBuilder
    private func listIndented(_ view: some View, block: MarkdownBlock) -> some View {
        if block.listDepth > 0 {
            let row = HStack(alignment: .firstTextBaseline, spacing: 0) {
                markerView(block.marker)
                    .foregroundStyle(.secondary)
                    .frame(width: markerWidth, alignment: .leading)
                view
            }
            .padding(.leading, CGFloat(block.listDepth - 1) * markerWidth)
            if block.isText {
                row.accessibilityElement(children: .combine)
            } else {
                row
            }
        } else {
            view
        }
    }

    /// A list marker. Bullets are drawn shapes rather than "•" / "◦" characters, whose hollow
    /// form is too small in the system font to tell apart from the filled one; VoiceOver reads
    /// them as "Bullet". Numbers stay text.
    @ViewBuilder
    private func markerView(_ marker: MarkdownBlock.ListMarker?) -> some View {
        switch marker {
        case .number(let number):
            Text(verbatim: number)
                .font(.body)
        case .bullet(let level):
            bulletShape(level: level)
                .frame(width: bulletSize, height: bulletSize)
                .alignmentGuide(.firstTextBaseline) { dimensions in dimensions.height + bulletLift }
                .accessibilityElement()
                .accessibilityLabel(Text("Bullet"))
        case nil:
            // A later block of the same item: keep the column, draw nothing.
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func bulletShape(level: Int) -> some View {
        switch level {
        case 1:
            Circle().fill(.secondary)
        case 2:
            Circle().strokeBorder(.secondary, lineWidth: 1.2)
        default:
            Rectangle().fill(.secondary)
                .padding(0.5)
        }
    }

    /// Draws a quote's leading bar; nested quotes are indented further.
    @ViewBuilder
    private func quoted(_ view: some View, depth: Int) -> some View {
        if depth > 0 {
            view
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 3)
                }
                .padding(.leading, CGFloat(depth - 1) * 12)
        } else {
            view
        }
    }

    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1:  return .title2.bold()
        case 2:  return .title3.bold()
        case 3:  return .headline
        default: return .subheadline.bold()
        }
    }
}

// MARK: - Table

/// A Markdown table: the header row in bold, column alignments from the `:--`, `:-:` and `--:`
/// delimiter row. Cells keep their natural width; a table wider than the card scrolls
/// horizontally instead of wrapping every cell.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) {
                grid
            }
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    Text(table.header[column])
                        .font(.body.bold())
                        .fixedSize()
                        .gridColumnAlignment(alignment(of: column))
                }
            }
            // Without this the Divider takes all the width offered and stretches the grid
            // (and its columns) across the card; it then spans only the columns' width.
            Divider()
                .gridCellUnsizedAxes(.horizontal)
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        Text(table.rows[row][column])
                            .font(.body)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func alignment(of column: Int) -> HorizontalAlignment {
        guard column < table.alignments.count else { return .leading }
        switch table.alignments[column] {
        case .center: return .center
        case .right:  return .trailing
        default:      return .leading
        }
    }
}

// MARK: - Block Model

/// One laid-out block of a Markdown note, with the lists and quotes that contain it.
struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case code(String)
        case rule
        case table(MarkdownTable)
    }

    /// The marker drawn before a list item's first block.
    enum ListMarker: Equatable {
        /// A bullet, by nesting level as in browsers and Pages: 1 a filled disc, 2 a hollow
        /// circle, 3 and deeper a filled square. Counts every enclosing list, numbered or not.
        case bullet(level: Int)
        /// A numbered item's number with its period, e.g. "3.".
        case number(String)
    }

    let id: Int
    var kind: Kind

    /// A heading or paragraph, whose list marker VoiceOver reads with it.
    var isText: Bool {
        switch kind {
        case .heading, .paragraph: return true
        case .code, .rule, .table: return false
        }
    }
    /// Number of list items containing the block (0 outside lists).
    let listDepth: Int
    /// The list marker on an item's first block; nil on its later blocks.
    let marker: ListMarker?
    /// Number of quotes containing the block.
    let quoteDepth: Int
}

struct MarkdownTable {
    var alignments: [PresentationIntent.TableColumn.Alignment]
    var header: [AttributedString]
    var rows: [[AttributedString]]
}

// MARK: - Parsing

enum MarkdownParser {
    /// Parses a note into blocks. Never throws: text the parser cannot read is shown as one
    /// plain paragraph.
    static func blocks(from source: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: keepingLineBreaks(source), options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph(AttributedString(source)), listDepth: 0, marker: nil, quoteDepth: 0)]
        }

        var blocks: [MarkdownBlock] = []
        var markedListItems = Set<Int>()
        var tableBlockIndex: [Int: Int] = [:]   // table identity → index in `blocks`

        for (intent, range) in attributed.runs[\.presentationIntent] {
            let text = AttributedString(attributed[range])
            guard let components = intent?.components, let innermost = components.first else {
                blocks.append(MarkdownBlock(id: blocks.count, kind: .paragraph(text), listDepth: 0, marker: nil, quoteDepth: 0))
                continue
            }

            // Containers, innermost first: count list items and quotes, and give an item's
            // first block its marker (a bullet by nesting level, or "n." when numbered).
            var listDepth = 0
            var quoteDepth = 0
            var marker: MarkdownBlock.ListMarker?
            for (index, component) in components.enumerated() {
                switch component.kind {
                case .listItem(let ordinal):
                    listDepth += 1
                    if listDepth == 1, markedListItems.insert(component.identity).inserted {
                        let isOrdered = components[(index + 1)...].first { $0.kind == .orderedList || $0.kind == .unorderedList }?.kind == .orderedList
                        let nestedLists = components[(index + 1)...].filter { if case .listItem = $0.kind { return true } else { return false } }.count
                        marker = isOrdered
                            ? .number(Double(ordinal).localizedString(decimals: 0) + ".")
                            : .bullet(level: nestedLists + 1)
                    }
                case .blockQuote:
                    quoteDepth += 1
                default:
                    break
                }
            }

            // Table cells: collect every cell of one table into a single block.
            if let table = components.first(where: { if case .table = $0.kind { return true } else { return false } }),
               case .table(let columns) = table.kind {
                let blockIndex: Int
                if let existing = tableBlockIndex[table.identity] {
                    blockIndex = existing
                } else {
                    blockIndex = blocks.count
                    tableBlockIndex[table.identity] = blockIndex
                    let empty = MarkdownTable(alignments: columns.map(\.alignment),
                                              header: Array(repeating: AttributedString(), count: columns.count),
                                              rows: [])
                    blocks.append(MarkdownBlock(id: blockIndex, kind: .table(empty), listDepth: listDepth, marker: marker, quoteDepth: quoteDepth))
                }
                guard case .table(var tableContent) = blocks[blockIndex].kind,
                      case .tableCell(let column) = innermost.kind,
                      column >= 0, column < columns.count else { continue }
                if components.contains(where: { $0.kind == .tableHeaderRow }) {
                    tableContent.header[column] = text
                } else if let row = components.lazy.compactMap({ component -> Int? in
                    if case .tableRow(let rowIndex) = component.kind { return rowIndex } else { return nil }
                }).first, row >= 1 {
                    while tableContent.rows.count < row {
                        tableContent.rows.append(Array(repeating: AttributedString(), count: columns.count))
                    }
                    tableContent.rows[row - 1][column] = text
                }
                blocks[blockIndex].kind = .table(tableContent)
                continue
            }

            let kind: MarkdownBlock.Kind
            switch innermost.kind {
            case .header(let level):
                kind = .heading(level: level, text: text)
            case .codeBlock:
                var code = String(text.characters)
                while code.hasSuffix("\n") { code.removeLast() }
                kind = .code(code)
            case .thematicBreak:
                kind = .rule
            default:
                kind = .paragraph(text)
            }
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind, listDepth: listDepth, marker: marker, quoteDepth: quoteDepth))
        }
        return blocks
    }

    /// Markdown joins consecutive lines into one paragraph. Ending each non-empty line outside
    /// fenced code blocks with two spaces (a hard line break) keeps the lines the user typed.
    /// Tables, lists and headings parse the same with them; code blocks are left untouched.
    /// As in Markdown, a fence closes only with the character that opened it, so a "```" line
    /// inside a "~~~" block (or the reverse) stays code.
    static func keepingLineBreaks(_ source: String) -> String {
        var openFence: Character?
        return source.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let fence: Character? = trimmed.hasPrefix("```") ? "`" : (trimmed.hasPrefix("~~~") ? "~" : nil)
            if let fence {
                if openFence == nil {
                    openFence = fence
                } else if openFence == fence {
                    openFence = nil
                }
                return line
            }
            return openFence != nil || trimmed.isEmpty ? line : line + "  "
        }.joined(separator: "\n")
    }
}

/// Parsed notes, so a redraw of the dive page (e.g. while scrubbing the profile chart) does not
/// re-parse them. Small: only the notes currently on screen are needed.
private enum MarkdownBlockCache {
    private static var entries: [String: [MarkdownBlock]] = [:]

    static func blocks(for source: String) -> [MarkdownBlock] {
        if let cached = entries[source] { return cached }
        if entries.count >= 16 { entries.removeAll() }
        let blocks = MarkdownParser.blocks(from: source)
        entries[source] = blocks
        return blocks
    }
}
