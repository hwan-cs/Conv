import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lays an `HwpDocument` out as HTML for `PagedPDFRenderer`, one page setup per section.
struct HwpHTMLWriter {
    struct Output {
        var html: String
        var page: PagedPDFRenderer.PageSetup
    }

    private let document: HwpDocument
    private var images: [Int: String] = [:]

    private var imageSizes: [Int: CGSize] = [:]
    private var effectImages: [ImageKey: String] = [:]

    private struct ImageKey: Hashable {
        let id: Int
        let effect: HwpDocument.Picture.Effect
    }
    /// The current paragraph's line gap: Hangul adds it below a line that holds an object, as below text.
    private var objectGap = 0
    private var headings: HwpHeadings
    private var defaultTab = 4000
    /// Set while drawing headers and footers, for their page-number fields.
    private var pageNumber: Int?
    private var pageCount: Int?
    private var anchor: Anchor?
    /// While writing an endnote: its number, as its own number field shows it.
    private var endnote: (number: Int, shape: HwpDocument.NoteShape)?

    init(document: HwpDocument) {
        self.document = document
        headings = HwpHeadings(document: document)
    }

    mutating func sections() -> [Output] {
        document.sections.enumerated().map { index, section in
            headings.outlineNumberingID = section.outlineNumberingID
            defaultTab = section.defaultTab
            let page = section.page
            let setup = PagedPDFRenderer.PageSetup(
                paperSize: CGSize(width: pt(page.width), height: pt(page.height)),
                margins: .init(
                    top: pt(page.top + page.header),
                    left: pt(page.left + page.gutter) - Self.bleed,
                    bottom: pt(page.bottom + page.footer - Self.bottomSlack(section)),
                    right: pt(page.right) - Self.bleed
                )
            )
            let columns = section.columns > 1
                ? "columns:\(section.columns);column-gap:\(decimal(pt(section.columnGap)))pt;"
                : ""
            if let pages = savedPages(section) {
                let paper = PagedPDFRenderer.PageSetup(
                    paperSize: setup.paperSize,
                    margins: .init(top: 0, left: 0, bottom: 0, right: 0)
                )
                return Output(html: Self.htmlPage(pages, bleed: 0), page: paper)
            }
            let placements = Self.placements(section.paragraphs, inBody: true, columns: section.columns)
            var body = zip(section.paragraphs, placements).map { paragraph($0, placement: $1) }.joined()
            if index == document.sections.count - 1 {
                for (number, note) in Self.endnotes(in: document.sections.flatMap(\.paragraphs)).enumerated() {
                    endnote = (section.endnoteShape.start + number, section.endnoteShape)
                    body += note.map { paragraph($0) }.joined()
                }
                endnote = nil
            }
            return Output(html: Self.htmlPage("<div class=\"section\" style=\"\(columns)\">\(body)</div>"), page: setup)
        }
    }

    // MARK: Pages from the saved layout
    private mutating func savedPages(_ section: HwpDocument.Section) -> String? {
        let paragraphs = section.paragraphs
        guard !paragraphs.isEmpty, paragraphs.allSatisfy({ !$0.lineSegments.isEmpty }) else {
            return nil
        }
        for paragraph in paragraphs {
            let tallest = paragraph.lineSegments.map(\.lineHeight).max() ?? 0
            for item in paragraph.content {
                if case .control(.table(let table)) = item, table.layout.inline, table.layout.height > tallest + 100 {
                    return nil
                }
            }
        }

        let page = section.page
        let placements = Self.placements(paragraphs, inBody: true, columns: section.columns)
        var pages: [String] = [""]
        let bodyWidth = page.width - page.left - page.right - page.gutter
        let gap = section.columns > 1 ? section.columnGap : 0
        let columnStep = (bodyWidth - gap * (section.columns - 1)) / section.columns + gap
        var column = 0
        var bottom = 0
        for (paragraph, placement) in zip(paragraphs, placements) {
            var starts = [0] + placement.breaks.keys.filter { $0 > 0 }.sorted()
            starts = Array(Set(starts)).sorted()
            for (index, start) in starts.enumerated() {
                let end = index + 1 < starts.count ? starts[index + 1] : paragraph.lineSegments.count
                switch placement.breaks[start] {
                case .page:
                    pages.append("")
                    column = 0
                case .column:
                    column += 1
                case nil:
                    break
                }
                pages[pages.count - 1] += piece(paragraph, lines: start..<end, column: column * columnStep, top: paragraph.lineSegments[start].verticalPosition, page: page)
                let last = paragraph.lineSegments[end - 1]
                bottom = last.verticalPosition + last.lineHeight + last.spacing
            }
        }

        let bodyHeight = page.height - page.top - page.header - page.bottom - page.footer

        if section.paragraphs.count > 0, document.sections.last.map({ $0.paragraphs.count == section.paragraphs.count }) ?? false {
            let notes = Self.endnotes(in: document.sections.flatMap(\.paragraphs))
            var origin = bottom
            for (index, note) in notes.enumerated() {
                endnote = (section.endnoteShape.start + index, section.endnoteShape)
                var previousBottom = origin
                for paragraph in note where !paragraph.lineSegments.isEmpty {
                    var start = 0
                    for (line, segment) in paragraph.lineSegments.enumerated() {
                        if origin + segment.verticalPosition < previousBottom - 1 {
                            origin = previousBottom - segment.verticalPosition
                        }
                        let top = origin + segment.verticalPosition
                        defer {
                            previousBottom = origin + segment.verticalPosition + segment.lineHeight + segment.spacing
                        }
                        guard top + segment.lineHeight > bodyHeight, top > 0 else {
                            continue
                        }
                        
                        if line > start {
                            pages[pages.count - 1] += piece(paragraph, lines: start..<line, column: column * columnStep, top: origin + paragraph.lineSegments[start].verticalPosition, page: page)
                        }
                        column += 1
                        if column >= section.columns {
                            column = 0
                            pages.append("")
                        }
                        origin = -segment.verticalPosition
                        start = line
                    }
                    let count = paragraph.lineSegments.count
                    pages[pages.count - 1] += piece(paragraph, lines: start..<count, column: column * columnStep, top: origin + paragraph.lineSegments[start].verticalPosition, page: page)
                    let last = paragraph.lineSegments[count - 1]
                    bottom = origin + last.verticalPosition + last.lineHeight
                }
                origin = bottom + section.endnoteShape.spaceBetween
            }
            endnote = nil
        }
        return pages.enumerated().map { index, html in
            let breakAfter = index < pages.count - 1 ? "break-after:page;" : ""
            return "<div style=\"position:relative;height:\(decimal(pt(page.height) - 1))pt;overflow:hidden;\(breakAfter)\"><div style=\"position:absolute;left:\(decimal(pt(page.left + page.gutter)))pt;top:\(decimal(pt(page.top + page.header)))pt;width:\(decimal(pt(bodyWidth)))pt;height:\(decimal(pt(bodyHeight)))pt;\">\(html)</div></div>"
        }.joined()
    }

    /// Lines of a paragraph placed at a column's left edge and a top, in body coordinates.
    private mutating func piece(_ paragraph: HwpDocument.Paragraph, lines: Range<Int>, column: Int, top: Int, page: HwpDocument.PageDef) -> String {
        let shape = document.paraShapes[safe: paragraph.paraShapeID] ?? HwpDocument.ParaShape()
        let segment = paragraph.lineSegments[lines.lowerBound]
        let columnX = column + segment.columnStart - shape.left
        let columnWidth = segment.width + shape.left + shape.right
        anchor = Anchor(page: page, x: columnX, y: top, columnWidth: columnWidth, left: shape.left, right: shape.right)
        defer {
            anchor = nil
        }
        let html = self.paragraph(paragraph, placement: Placement(savedGap: 0, lines: lines))
        return "<div style=\"position:absolute;left:\(decimal(pt(columnX)))pt;top:\(decimal(pt(top)))pt;width:\(decimal(pt(columnWidth)))pt;\">\(html)</div>"
    }

    /// Every endnote's paragraphs, in the order their references appear.
    static func endnotes(in paragraphs: [HwpDocument.Paragraph]) -> [[HwpDocument.Paragraph]] {
        var notes: [[HwpDocument.Paragraph]] = []
        for paragraph in paragraphs {
            for item in paragraph.content {
                guard case .control(let control) = item else {
                    continue
                }
                switch control {
                case .endnote(let note):
                    notes.append(note)
                case .table(let table):
                    notes += table.cells.flatMap { endnotes(in: $0.paragraphs) }
                default:
                    break
                }
            }
        }
        return notes
    }

    // MARK: Headers and footers
    func pageNumberStart(section index: Int) -> Int? {
        let start = document.sections[index].pageNumberStart
        return start > 0 ? start : nil
    }

    mutating func overlay(section index: Int, pageCount: Int, firstPageNumber: Int) -> Output? {
        let section = document.sections[index]
        typealias Placed = (page: Int, control: HwpDocument.Control)
        var placed: [Placed] = []
        var page = 0
        for (paragraph, placement) in zip(section.paragraphs, Self.placements(section.paragraphs, inBody: true, columns: section.columns)) {
            if placement.breaks[0] == .page {
                page += 1
            }
            for item in paragraph.content {
                if case .control(let control) = item {
                    placed.append((page, control))
                }
            }
            page += placement.breaks.filter { $0.key > 0 && $0.value == .page }.count
        }
        let relevant = placed.filter {
            switch $0.control {
            case .header, .footer, .pageNumberPosition, .pageHide:
                true
            default:
                false
            }
        }
        guard relevant.contains(where: { if case .pageHide = $0.control { false } else { true } }) else {
            return nil
        }

        let paper = section.page
        let width = paper.width - paper.left - paper.right - paper.gutter
        var sheets: [String] = []
        for sheet in 0..<pageCount {
            let number = firstPageNumber + sheet
            pageNumber = number
            self.pageCount = pageCount
            var headers: [HwpDocument.HeaderFooter.Pages: HwpDocument.HeaderFooter] = [:]
            var footers: [HwpDocument.HeaderFooter.Pages: HwpDocument.HeaderFooter] = [:]
            var position: HwpDocument.PageNumberPosition?
            var hidden = (header: false, footer: false, pageNumber: false)
            for item in relevant where item.page <= sheet {
                switch item.control {
                case .header(let header):
                    headers[header.pages] = header
                case .footer(let footer):
                    footers[footer.pages] = footer
                case .pageNumberPosition(let value):
                    position = value
                case .pageHide(let header, let footer, let pageNumber) where item.page == sheet:
                    hidden = (hidden.header || header, hidden.footer || footer, hidden.pageNumber || pageNumber)
                default:
                    break
                }
            }
            let parity: HwpDocument.HeaderFooter.Pages = number % 2 == 0 ? .even : .odd
            var html = ""
            let box = "position:absolute;left:\(decimal(pt(paper.left + paper.gutter)))pt;width:\(decimal(pt(width)))pt;"
            if !hidden.header, let header = headers[parity] ?? headers[.both] {
                html += "<div style=\"\(box)top:\(decimal(pt(paper.top)))pt;\">\(list(header.paragraphs))</div>"
            }
            if !hidden.footer, let footer = footers[parity] ?? footers[.both] {
                let top = paper.height - paper.bottom - paper.footer
                html += "<div style=\"\(box)top:\(decimal(pt(top)))pt;\">\(list(footer.paragraphs))</div>"
            }
            if !hidden.pageNumber, let position, position.position != 0 {
                html += pageNumberHTML(position, number: number, box: box, paper: paper)
            }
            sheets.append(html)
        }
        pageNumber = nil
        self.pageCount = nil

        let height = decimal(pt(paper.height) - 1)
        let body = sheets.enumerated().map { index, html in
            let breakAfter = index < sheets.count - 1 ? "break-after:page;" : ""
            return "<div style=\"position:relative;height:\(height)pt;overflow:hidden;\(breakAfter)\">\(html)</div>"
        }.joined()
        let setup = PagedPDFRenderer.PageSetup(
            paperSize: CGSize(width: pt(paper.width), height: pt(paper.height)),
            margins: .init(top: 0, left: 0, bottom: 0, right: 0)
        )
        return Output(html: Self.htmlPage(body, bleed: 0), page: setup)
    }

    /// 쪽 번호 위치: at the top of the header area or with its line on the bottom margin.
    private func pageNumberHTML(_ position: HwpDocument.PageNumberPosition, number: Int, box: String, paper: HwpDocument.PageDef) -> String {
        var text = position.prefix + Self.format(number, style: position.style) + position.suffix
        if !position.dash.isEmpty {
            text = "\(position.dash) \(text) \(position.dash)"
        }
        let odd = number % 2 == 1
        let (top, align): (Bool, String) = switch position.position {
        case 1:
            (true, "left")
        case 2:
            (true, "center")
        case 3:
            (true, "right")
        case 4:
            (false, "left")
        case 6:
            (false, "right")
        case 7:
            (true, odd ? "right" : "left")
        case 8:
            (false, odd ? "right" : "left")
        case 9:
            (true, odd ? "left" : "right")
        case 10:
            (false, odd ? "left" : "right")
        default:
            (false, "center")
        }
        let shape = document.charShapes.first
        let size = Double(shape?.height ?? 1000) / 100
        let y = top ? pt(paper.top) : pt(paper.height - paper.bottom) - size
        let font = HwpFonts.choice(for: shape.flatMap { document.fonts[0][safe: $0.faces[0]] })
        return "<div style=\"\(box)top:\(decimal(y))pt;text-align:\(align);font-family:\(font.family);font-size:\(decimal(size))pt;line-height:1;\">\(Self.escape(text))</div>"
    }

    static func bottomSlack(_ section: HwpDocument.Section) -> Int {
        let saved = section.paragraphs.flatMap(\.lineSegments).map(\.spacing).max()
        return (saved ?? 600) + 100
    }

    // MARK: Paragraphs
    enum Break: String {
        case page, column
    }

    /// How a paragraph sits among its neighbours.
    struct Placement {
        var closesList = false
        var breaks: [Int: Break] = [:]
        var savedGap: Int?
        /// The lines to write, when a paragraph is split across columns or pages; nil for all.
        var lines: Range<Int>?
    }

    /// Where the paragraph being written sits on its page, when pages are built from the saved layout
    struct Anchor {
        var page: HwpDocument.PageDef
        var x: Int
        var y: Int
        var columnWidth: Int
        /// The paragraph's own margins inside the column.
        var left: Int
        var right: Int
    }

    /// Placements from Hangul's saved line positions. In the body, a line placed above the one
    /// before it starts the next column, or a new page after the last column.
    static func placements(_ paragraphs: [HwpDocument.Paragraph], inBody: Bool, columns: Int = 1) -> [Placement] {
        var result: [Placement] = []
        var previous: HwpDocument.LineSegment?
        var column = 0
        for paragraph in paragraphs {
            var placement = Placement()
            for (line, segment) in paragraph.lineSegments.enumerated() {
                if inBody, let previous, segment.verticalPosition < previous.verticalPosition {
                    if column + 1 < columns {
                        placement.breaks[line] = .column
                        column += 1
                    } else {
                        placement.breaks[line] = .page
                        column = 0
                    }
                }
                if line == 0 {
                    let end = previous.map { $0.verticalPosition + $0.lineHeight + $0.spacing } ?? 0
                    placement.savedGap = placement.breaks[0] == nil ? segment.verticalPosition - end : segment.verticalPosition
                }
                previous = segment
            }
            result.append(placement)
        }
        if !result.isEmpty {
            result[result.count - 1].closesList = !inBody
        }
        return result
    }

    private mutating func paragraph(_ paragraph: HwpDocument.Paragraph, placement: Placement = Placement()) -> String {
        var shape = document.paraShapes[safe: paragraph.paraShapeID] ?? HwpDocument.ParaShape()
        var style = ""
        let writesFirstLine = placement.lines?.contains(0) ?? true
        let head = self.head(shape, charShapeID: paragraph.charShapeID, advance: writesFirstLine)
        if head.autoIndent {
            let width = Int(head.width * 100)
            shape.left += width
            shape.indent -= width
        }
        let left = shape.left - min(shape.indent, 0)
        if left != 0 {
            style += "margin-left:\(decimal(pt(left)))pt;"
        }
        if shape.right != 0 {
            style += "margin-right:\(decimal(pt(shape.right)))pt;"
        }
        if shape.indent != 0 {
            style += "text-indent:\(decimal(pt(shape.indent)))pt;"
        }

        let firstShape = document.charShapes[safe: paragraph.charShapeID]
        let gap = lineGap(shape.lineSpacing, height: firstShape?.height ?? 1000)
        
        let isSaved = placement.savedGap != nil
        let spacing: HwpDocument.ParaShape.LineSpacing = isSaved ? .percent(100) : shape.lineSpacing
        let outerGap = objectGap
        objectGap = isSaved ? 0 : gap
        defer {
            objectGap = outerGap
        }
        let breaks = placement.breaks
        let segments = paragraph.lineSegments
        var blocks: [String] = []
        var trailing: [String] = []
        var blocksHeight = 0
        if placement.savedGap == nil {
            let top = shape.spaceBefore - gap / 2
            let bottom = shape.spaceAfter + (placement.closesList ? -gap / 2 : gap / 2)
            if top != 0 {
                style += "margin-top:\(decimal(pt(top)))pt;"
            }
            if bottom != 0 {
                style += "margin-bottom:\(decimal(pt(bottom)))pt;"
            }
        }

        let justified: Bool
        switch shape.alignment {
        case .justify:
            style += "text-align:justify;"
            justified = true
        case .left:
            justified = false
        case .right:
            style += "text-align:right;"; justified = false
        case .center:
            style += "text-align:center;"; justified = false
        case .distribute, .divide:
            style += "text-align:justify;text-align-last:justify;"
            justified = true
        }
        if let id = shape.borderFillID, let fill = document.borderFills[safe: id - 1] {
            style += boxStyle(fill)
        }
        if paragraph.pageBreak || shape.pageBreakBefore || breaks[0] == .page {
            style += "break-before:page;"
        }
        if breaks[0] == .column {
            style += "break-before:column;"
        }
        if paragraph.columnBreak {
            style += "break-before:column;"
        }

        // Where Hangul saved its line breaks, each line is laid out on its own so lines break where Hangul's do.
        let lines = paragraph.content.split(omittingEmptySubsequences: false) {
            if case .lineStart = $0 {
                true
            } else {
                false
            }
        }
        var html = ""
        for (number, line) in lines.enumerated() where placement.lines?.contains(number) ?? true {
            var content = number == 0 ? run("\u{200B}", shapeID: paragraph.charShapeID, spacing: spacing) : ""
            if number == 0, !head.label.isEmpty {
                content += run(head.label, shapeID: head.shapeID, spacing: spacing)
                content += "<span style=\"display:inline-block;width:\(decimal(head.gap))pt\"></span>"
            }
            var parts: [(end: Int, next: Int, width: Double)] = []
            var tabShapes: [Int] = []
            var estimate = number == 0 ? head.width : 0
            var endsWithBreak = false
            var tallestTable = 0
            let holdsTab = line.contains { if case .tab = $0 { true } else { false } }
            for (index, item) in zip(line.indices, line) {
                let isLast = index == line.index(before: line.endIndex)
                switch item {
                case .text(var text, let id):
                    if lines.count > 1, isLast {
                        while text.last == " " {
                            text.removeLast()
                        }
                    }
                    content += run(text, shapeID: id, spacing: spacing)
                    estimate += width(of: text, shapeID: id)
                case .tab(let id):
                    let end = content.utf8.count
                    content += tab(shape, charShapeID: id)
                    parts.append((end, content.utf8.count, estimate))
                    tabShapes.append(id)
                    estimate = 0
                case .lineBreak:
                    if lines.count > 1, isLast {
                        endsWithBreak = true
                    } else {
                        content += "<br>"
                    }
                case .lineStart:
                    break
                case .control(let control):
                    switch control {
                    case .table(let table):
                        if table.layout.inline {
                            content += self.table(table, inline: true)
                            tallestTable = max(tallestTable, table.layout.height)
                        } else {
                            if anchor != nil {
                                content += floating(self.table(table, inline: false), layout: table.layout)
                                continue
                            }
                            
                            let textHeight = firstShape?.height ?? 1000
                            if table.layout.vertical == .paragraph, table.layout.y >= textHeight {
                                trailing.append(self.table(table, inline: false, below: textHeight + gap))
                                continue
                            }
                            blocks.append(self.table(table, inline: false))
                            let layout = table.layout
                            blocksHeight += layout.height + layout.y + layout.margins.top + layout.margins.bottom
                        }
                    case .picture(let picture):
                        content += self.picture(picture)
                    case .shape(let shape):
                        content += self.shape(shape)
                    case .equation(let equation):
                        content += self.equation(equation)
                    case .autoNumber(let number):
                        if number.kind == .endnote, let endnote {
                            let label = endnote.shape.prefix + Self.format(endnote.number, style: number.style) + endnote.shape.suffix
                            content += run(label, shapeID: number.charShapeID, spacing: spacing)
                            break
                        }
                        let value = switch number.kind {
                        case .page:
                            pageNumber ?? number.number
                        case .totalPages:
                            pageCount ?? number.number
                        default:
                            number.number
                        }
                        content += run(Self.format(value, style: number.style), shapeID: number.charShapeID, spacing: spacing)
                    default:
                        break
                    }
                }
            }
            let saved = placement.savedGap != nil ? segments[safe: number] : nil
            if lines.count == 1, saved == nil {
                html = content
                break
            }
            var lineStyle = number > 0 ? "text-indent:0;" : ""
            if let saved {
                let isLast = placement.closesList && number == lines.count - 1
                let height = saved.lineHeight + (isLast ? 0 : saved.spacing)
                let grows = tallestTable > saved.lineHeight
                lineStyle += "\(grows ? "min-height" : "height"):\(decimal(pt(height)))pt;"
            }
            if number > 0, let lineBreak = breaks[number] {
                lineStyle += "break-before:\(lineBreak.rawValue);"
            }
            if holdsTab, saved != nil {
                let bytes = Array(content.utf8)
                var pieces: [(html: String, width: Double)] = []
                var begin = 0
                for part in parts + [(bytes.count, bytes.count, estimate)] {
                    pieces.append((String(decoding: bytes[begin..<part.end], as: UTF8.self), part.width))
                    begin = part.next
                }
                html += tabbedLine(pieces, tabShapes: tabShapes, shape: shape, isFirst: number == 0, style: lineStyle, spacing: spacing)
                continue
            }
            if holdsTab {
                lineStyle += "text-align:left;text-align-last:auto;"
            } else if justified, number < lines.count - 1, !endsWithBreak {
                lineStyle += "text-align-last:justify;"
            }
            html += "<span class=\"line\" style=\"\(lineStyle)\">\(content)</span>"
        }
        if let savedGap = placement.savedGap {
            let edge = breaks[0] == nil ? "margin-top" : "padding-top"
            style += "\(edge):\(decimal(pt(savedGap - blocksHeight)))pt;"
        }
        if shape.alignment == .distribute || shape.alignment == .divide, let spread = spreadLetters(paragraph, spacing: spacing) {
            var lineStyle = ""
            if let saved = placement.savedGap != nil ? segments.first : nil {
                let height = saved.lineHeight + (placement.closesList ? 0 : saved.spacing)
                lineStyle = "height:\(decimal(pt(height)))pt;"
            }
            return blocks.joined() + "<div class=\"p\" style=\"\(style)\(lineStyle)display:flex;justify-content:space-between;\">\(spread)</div>" + trailing.joined()
        }
        return blocks.joined() + "<div class=\"p\" style=\"\(style)\">\(html)</div>" + trailing.joined()
    }

    /// A saved line with tabs, as a row of slots from stop to stop: what follows a left tab starts
    /// at its stop, what precedes a right tab ends there, and leaders fill the gaps. Which stop a tab
    /// reaches is decided from estimated widths; where things land is then exact.
    private func tabbedLine(
        _ pieces: [(html: String, width: Double)],
        tabShapes: [Int],
        shape: HwpDocument.ParaShape,
        isFirst: Bool,
        style: String,
        spacing: HwpDocument.ParaShape.LineSpacing
    ) -> String {
        let definition = document.tabDefs[safe: shape.tabDefID] ?? HwpDocument.TabDef()
        let hang = pt(max(-shape.indent, 0))
        var stops = definition.stops.map { (position: pt($0.position), kind: $0.kind, leader: $0.leader) }
        if definition.hangingStop, hang > 0 {
            stops.append((hang, .left, false))
        }
        stops.sort { $0.position < $1.position }

        let start = isFirst ? pt(max(shape.indent, 0)) : hang
        var slotStart = start
        var x = start + pieces[0].width
        var slot = pieces[0].html
        var html = ""
        func leader(_ on: Bool, shapeID: Int) -> String {
            guard on else {
                return "<span style=\"flex:1\"></span>"
            }
            let size = document.charShapes[safe: shapeID].map { decimal(Double($0.height) / 100) } ?? "10"
            return "<span style=\"flex:1;overflow:hidden;white-space:nowrap;text-align:right;font-size:\(size)pt;line-height:1;align-self:baseline\">\(String(repeating: "·", count: 200))</span>"
        }
        func close(width: Double?) {
            let size = width.map { "width:\(decimal(max($0, 0)))pt;flex:none;" } ?? "flex:1;"
            html += "<span style=\"display:flex;align-items:baseline;white-space:pre;\(size)\">\(slot)</span>"
        }
        for (index, shapeID) in tabShapes.enumerated() {
            let next = pieces[index + 1]
            if let stop = stops.first(where: { $0.position > x + 0.5 }) {
                switch stop.kind {
                case .left:
                    slot += leader(stop.leader, shapeID: shapeID)
                    close(width: stop.position - slotStart)
                    slot = next.html
                    x = stop.position + next.width
                case .right, .center, .decimal:
                    let overhang = stop.kind == .center ? next.width / 2 : 0
                    slot += leader(stop.leader, shapeID: shapeID) + next.html
                    close(width: stop.position + overhang - slotStart)
                    slot = ""
                    x = stop.position + overhang
                }
                slotStart = stop.position + (stop.kind == .left ? 0 : (stop.kind == .center ? next.width / 2 : 0))
            } else if definition.rightEndStop {
                slot += leader(false, shapeID: shapeID) + next.html
                close(width: nil)
                slot = ""
                x = .infinity
            } else {
                let step = max(pt(defaultTab), 1)
                let stop = (floor(x / step + 0.001) + 1) * step
                slot += leader(false, shapeID: shapeID)
                close(width: stop - slotStart)
                slotStart = stop
                slot = next.html
                x = stop + next.width
            }
        }
        if !slot.isEmpty {
            html += "<span style=\"white-space:pre;flex:none\">\(slot)</span>"
        }
        let shift = isFirst ? "margin-left:\(decimal(-hang))pt;" : ""
        return "<span class=\"line\" style=\"\(style)display:flex;align-items:baseline;\(shift)\">\(html)</span>"
    }

    /// Hangul's own advance for text, from the face it would use: the 함초롬 or full-width widths
    /// the stand-ins are spaced to, scaled by 장평 and spaced by 자간.
    private func width(of text: String, shapeID: Int) -> Double {
        guard let shape = document.charShapes[safe: shapeID] else {
            return 0
        }
        var total = 0.0
        for character in text {
            let script = Self.script(of: character)
            let size = Double(shape.height) / 100 * Double(shape.relativeSizes[script]) / 100
            let font = HwpFonts.choice(for: document.fonts[script][safe: shape.faces[script]])
            let ratio = Double(shape.ratios[script]) / 100
            let advance = character == " " ? font.target.space : (script == 1 || script == 4 ? font.target.latin : font.target.hangul)
            total += (advance * ratio + Double(shape.spacings[script]) / 100) * size
        }
        return total
    }

    /// A tab, sized by `fitLines` once the text before it is laid out. Stops are in points from the
    /// paragraph's left margin, which for a hanging paragraph lies left of its box by the hang.
    private func tab(_ shape: HwpDocument.ParaShape, charShapeID: Int) -> String {
        let definition = document.tabDefs[safe: shape.tabDefID] ?? HwpDocument.TabDef()
        var stops = definition.stops.map { stop in
            let kind = switch stop.kind {
            case .left: 
                "l"
            case .right: 
                "r"
            case .center: 
                "c"
            case .decimal: 
                "r"
            }
            return (stop.position, "\(decimal(pt(stop.position))):\(kind):\(stop.leader ? 1 : 0)")
        }
        let hang = max(-shape.indent, 0)
        if definition.hangingStop, hang > 0 {
            stops.append((hang, "\(decimal(pt(hang))):l:0"))
        }
        let list = stops.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: ",")
        let size = document.charShapes[safe: charShapeID].map { decimal(Double($0.height) / 100) } ?? "10"
        return "<span class=\"tab\" data-stops=\"\(list)\" data-default=\"\(decimal(pt(defaultTab)))\" data-origin=\"\(decimal(-pt(hang)))\"\(definition.rightEndStop ? " data-end=\"1\"" : "") style=\"font-size:\(size)pt\"></span>"
    }

    /// A paragraph's bullet or number (문단 머리) and the gap before its text, in points.
    struct Head {
        var label = ""
        var shapeID = 0
        var gap = 0.0
        /// Estimated, with the gap.
        var width = 0.0
        var autoIndent = false
    }

    /// - Parameter advance: Whether to count this paragraph; off for later pieces of a split one.
    private mutating func head(_ shape: HwpDocument.ParaShape, charShapeID: Int, advance: Bool = true) -> Head {
        guard let (label, spacing) = headings.head(shape.heading, advance: advance) else {
            return Head()
        }
        let shapeID = spacing.charShapeID.flatMap { document.charShapes.indices.contains($0) ? $0 : nil } ?? charShapeID
        let size = document.charShapes[safe: shapeID].map { Double($0.height) / 100 } ?? 10
        let gap = spacing.distanceIsPercent ? Double(spacing.distance) / 100 * size : pt(spacing.distance)
        return Head(label: label, shapeID: shapeID, gap: gap, width: width(of: label, shapeID: shapeID) + gap, autoIndent: spacing.autoIndent)
    }

    /// Bullets drawn from Hangul's symbol faces sit in the Private Use Area; most are common shapes.
    static func bulletCharacter(_ character: String) -> String {
        guard let scalar = character.unicodeScalars.first, (0xE000...0xF8FF).contains(scalar.value) else {
            return character
        }
        return switch scalar.value & 0xFF {
        case 0x6C, 0x9F, 0xA1: 
            "●"
        case 0x6E, 0xA7: 
            "■"
        case 0x71, 0x6F: 
            "□"
        case 0x75, 0xA8: 
            "◆"
        case 0xD8, 0xE0, 0xE8: 
            "➢"
        case 0xFC: 
            "✓"
        default: 
            "•"
        }
    }

    /// 번호 모양.
    static func format(_ value: Int, style: Int) -> String {
        switch style {
        case 1 where (1...20).contains(value):
            String(UnicodeScalar(0x2460 + value - 1)!)
        case 2:
            roman(value)
        case 3:
            roman(value).lowercased()
        case 4:
            letters(value)
        case 5:
            letters(value).lowercased()
        case 8:
            korean(value, from: Array("가나다라마바사아자차카타파하"))
        case 10:
            korean(value, from: Array("ㄱㄴㄷㄹㅁㅂㅅㅇㅈㅊㅋㅌㅍㅎ"))
        case 12:
            korean(value, from: Array("일이삼사오육칠팔구십"))
        case 13:
            korean(value, from: Array("一二三四五六七八九十"))
        default:
            String(value)
        }
    }

    private static func roman(_ value: Int) -> String {
        guard value > 0, value < 4000 else {
            return String(value)
        }
        let numerals = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var rest = value
        var result = ""
        for (amount, numeral) in numerals {
            while rest >= amount {
                result += numeral
                rest -= amount
            }
        }
        return result
    }

    private static func letters(_ value: Int) -> String {
        guard value > 0 else {
            return String(value)
        }
        let letter = String(UnicodeScalar(UInt8(65 + (value - 1) % 26)))
        return String(repeating: letter, count: (value - 1) / 26 + 1)
    }

    private static func korean(_ value: Int, from sequence: [Character]) -> String {
        guard value > 0 else {
            return String(value)
        }
        return String(sequence[(value - 1) % sequence.count])
    }

    /// 배분 정렬 spreads letters, not only words, across the line, which WebKit's justification
    /// can't do; a one-line paragraph of plain text becomes a row of letters instead.
    private func spreadLetters(_ paragraph: HwpDocument.Paragraph, spacing: HwpDocument.ParaShape.LineSpacing) -> String? {
        guard paragraph.lineSegments.count <= 1 else {
            return nil
        }
        var letters: [(Character, Int)] = []
        for item in paragraph.content {
            guard case .text(let text, let id) = item else {
                return nil
            }
            letters += text.map { ($0, id) }
        }
        let trimmed = letters.drop { $0.0 == " " }.reversed().drop { $0.0 == " " }.reversed()
        guard trimmed.count > 1, trimmed.count <= 24 else {
            return nil
        }
        return trimmed.map { run(String($0.0), shapeID: $0.1, spacing: spacing) }.joined()
    }

    private mutating func list(_ paragraphs: [HwpDocument.Paragraph]) -> String {
        let outer = anchor
        anchor = nil
        defer {
            anchor = outer
        }
        return zip(paragraphs, Self.placements(paragraphs, inBody: false)).map { paragraph($0, placement: $1) }.joined()
    }

    /// The space Hangul leaves below each line, for a line of the given text height.
    private func lineGap(_ spacing: HwpDocument.ParaShape.LineSpacing, height: Int) -> Int {
        switch spacing {
        case .percent(let percent):
            height * (percent - 100) / 100
        case .betweenLines(let value):
            value
        case .fixed(let value), .atLeast(let value):
            max(value - height, 0)
        }
    }

    private func lineHeightCSS(_ spacing: HwpDocument.ParaShape.LineSpacing) -> String {
        switch spacing {
        case .percent(let percent): 
            "\(percent)%"
        case .betweenLines(let value): 
            "calc(1em + \(decimal(pt(value)))pt)"
        case .fixed(let value): 
            "\(decimal(pt(value)))pt"
        case .atLeast(let value): 
            "max(1em, \(decimal(pt(value)))pt)"
        }
    }

    // MARK: Runs
    private func run(_ text: String, shapeID: Int, spacing: HwpDocument.ParaShape.LineSpacing) -> String {
        guard let shape = document.charShapes[safe: shapeID] else {
            return Self.escape(text)
        }
        var html = ""
        var current = ""
        var currentScript = -1
        for character in text {
            var script = Self.script(of: character)
            if character == " " || character == "\t" || character == "\u{200B}" {
                script = currentScript < 0 ? 0 : currentScript
            }
            if script != currentScript, !current.isEmpty {
                html += span(current, shape: shape, script: currentScript, spacing: spacing)
                current = ""
            }
            currentScript = script
            current.append(character)
        }
        if !current.isEmpty { html += span(current, shape: shape, script: max(currentScript, 0), spacing: spacing) }
        return html
    }

    private func span(_ text: String, shape: HwpDocument.CharShape, script: Int, spacing: HwpDocument.ParaShape.LineSpacing) -> String {
        let size = Double(shape.height) / 100 * Double(shape.relativeSizes[script]) / 100
        var style = "font-size:\(decimal(size))pt;line-height:\(lineHeightCSS(spacing));"
        let font = HwpFonts.choice(for: document.fonts[script][safe: shape.faces[script]])
        style += "font-family:\(font.family);"
        let ratio = Double(shape.ratios[script]) / 100
        let extra = Double(shape.spacings[script]) / 100
        let isLatin = script == 1 || script == 4
        let target = isLatin ? font.target.latin : font.target.hangul
        let actual = isLatin ? font.actual.latin : font.actual.hangul

        let letterSpacing = max(target * ratio - actual + extra, -Self.tightestSpacing)
        let wordSpacing = font.target.space * ratio - font.actual.space + extra - letterSpacing

        let isStrut = text == "\u{200B}"
        if abs(letterSpacing) > 0.001, !isStrut {
            style += "letter-spacing:\(decimal(letterSpacing))em;"
        }
        if abs(wordSpacing) > 0.001, !isStrut {
            style += "word-spacing:\(decimal(wordSpacing))em;"
        }
        if shape.bold {
            style += "font-weight:bold;"
        }
        if shape.italic {
            style += "font-style:italic;"
        }
        if shape.color != .black {
            style += "color:\(shape.color.css);"
        }
        var decorations: [String] = []
        if shape.underline == .below {
            decorations.append("underline")
        }
        if shape.underline == .above {
            decorations.append("overline")
        }
        if shape.strikeout {
            decorations.append("line-through")
        }
        if !decorations.isEmpty {
            style += "text-decoration:\(decorations.joined(separator: " "));"
        }
        if let shade = shape.shadeColor, shade != Self.white {
            style += "background:\(shade.css);"
        }
        if shape.isSuperscript {
            style += "vertical-align:super;font-size:\(decimal(size * 0.7))pt;"
        }
        if shape.isSubscript {
            style += "vertical-align:sub;font-size:\(decimal(size * 0.7))pt;"
        }
        let offset = shape.offsets[script]
        if offset != 0 {
            style += "position:relative;top:\(decimal(Double(offset) / 100 * size))pt;"
        }
        return "<span style=\"\(style)\">\(Self.escape(text))</span>"
    }

    private static let white = HwpDocument.Color(red: 255, green: 255, blue: 255)

    /// 0 한글, 1 영어, 2 한자, 3 일어, 4 기타, 5 기호, 6 사용자.
    static func script(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first?.value else {
            return 1
        }
        switch scalar {
        case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xD7B0...0xD7FF:
            return 0
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FFFF:
            return 2
        case 0x3040...0x30FF, 0x31F0...0x31FF:
            return 3
        case 0x2000...0x2BFF, 0x3000...0x303F, 0x3200...0x33FF, 0xFF00...0xFFEF, 0x25A0...0x25FF:
            return 5
        case 0...0x024F:
            return 1
        default:
            return 4
        }
    }

    // MARK: Tables
    /// - Parameter below: For a table following its paragraph's first line, that line's height,
    ///   which its offset from the paragraph's top already includes.
    private mutating func table(_ table: HwpDocument.Table, inline: Bool, below: Int = 0) -> String {
        let widths = Self.columnWidths(table)
        var style = "width:\(decimal(pt(widths.reduce(0, +))))pt;"
        if table.cellSpacing > 0 {
            style += "border-collapse:separate;border-spacing:\(decimal(pt(table.cellSpacing)))pt;"
        }
        if let fill = document.borderFills[safe: table.borderFillID - 1]?.fill {
            style += "background:\(fill.css);"
        }
        if inline {
            style += "display:inline-table;vertical-align:bottom;text-indent:0;text-align:left;margin-right:-2pt;"
        } else {
            style += tableBlockPlacement(table.layout, below: below)
        }
        if inline {
            let margins = table.layout.margins
            style += "margin-left:\(decimal(pt(margins.left)))pt;"
            style += "margin-top:\(decimal(pt(margins.top + objectGap / 2)))pt;"
            style += "margin-bottom:\(decimal(pt(margins.bottom + objectGap / 2)))pt;"
        }

        var html = "<table style=\"\(style)\"><colgroup>"
        html += widths.map { "<col style=\"width:\(decimal(pt($0)))pt\">" }.joined()
        html += "</colgroup>"
        let rows = Dictionary(grouping: table.cells, by: \.row)
        for row in 0..<table.rows {
            let cells = (rows[row] ?? []).sorted { $0.column < $1.column }
            let height = cells.filter { $0.rowSpan == 1 }.map(\.height).max() ?? 0
            html += "<tr style=\"height:\(decimal(pt(height)))pt\">"
            for cell in cells {
                html += self.cell(cell)
            }
            html += "</tr>"
        }
        return html + "</table>"
    }

    private func tableBlockPlacement(_ layout: HwpDocument.ObjectLayout, below: Int = 0) -> String {
        var style = ""
        switch layout.horizontalAlign {
        case 1: 
            style += "margin-left:auto;margin-right:auto;"
        case 2: 
            style += "margin-left:auto;"
        default:
            if layout.x != 0 {
                style += "margin-left:\(decimal(pt(layout.x)))pt;"
            }
        }
        let top = layout.y - below + layout.margins.top
        if top != 0 {
            style += "margin-top:\(decimal(pt(top)))pt;"
        }
        if layout.margins.bottom != 0 {
            style += "margin-bottom:\(decimal(pt(layout.margins.bottom)))pt;"
        }
        return style
    }

    private mutating func cell(_ cell: HwpDocument.Table.Cell) -> String {
        let fill = document.borderFills[safe: cell.borderFillID - 1]
        let top = pt(cell.padding.top) - (fill.map { Self.points($0.top) } ?? 0) / 2
        let bottom = pt(cell.padding.bottom) - (fill.map { Self.points($0.bottom) } ?? 0) / 2
        var style = "padding:\(decimal(max(top, 0)))pt \(decimal(pt(cell.padding.right)))pt \(decimal(max(bottom, 0)))pt \(decimal(pt(cell.padding.left)))pt;"
        style += "vertical-align:\(["top", "middle", "bottom"][min(cell.verticalAlign, 2)]);"
        if let fill {
            style += boxStyle(fill)
        }
        var attributes = ""
        if cell.columnSpan > 1 {
            attributes += " colspan=\"\(cell.columnSpan)\""
        }
        if cell.rowSpan > 1 {
            attributes += " rowspan=\"\(cell.rowSpan)\""
        }
        let body = list(cell.paragraphs)
        return "<td\(attributes) style=\"\(style)\">\(body)</td>"
    }

    /// Column widths from the cells' own widths: single-column cells first, then spans fill the gaps.
    static func columnWidths(_ table: HwpDocument.Table) -> [Int] {
        var widths = [Int?](repeating: nil, count: table.columns)
        for cell in table.cells where cell.columnSpan == 1 && cell.column < table.columns {
            widths[cell.column] = widths[cell.column] ?? cell.width
        }
        var changed = true
        while changed {
            changed = false
            for cell in table.cells where cell.columnSpan > 1 && cell.column < table.columns {
                let range = cell.column..<min(cell.column + cell.columnSpan, table.columns)
                let unknown = range.filter { widths[$0] == nil }
                guard !unknown.isEmpty else {
                    continue
                }
                let known = range.compactMap { widths[$0] }.reduce(0, +)
                let share = max(cell.width - known, 0) / unknown.count
                for column in unknown {
                    widths[column] = share
                }
                changed = true
            }
        }
        return widths.map { $0 ?? 0 }
    }

    /// A border's drawn width; hairlines are thickened to stay visible.
    static func points(_ border: HwpDocument.Border) -> Double {
        border.style == nil ? 0 : max(border.width * 72 / 25.4, 0.5)
    }

    private mutating func boxStyle(_ fill: HwpDocument.BorderFill) -> String {
        var style = ""
        for (name, border) in [("left", fill.left), ("right", fill.right), ("top", fill.top), ("bottom", fill.bottom)] {
            if let line = border.style {
                style += "border-\(name):\(decimal(Self.points(border)))pt \(line.css) \(border.color.css);"
            }
        }
        if let color = fill.fill {
            style += "background:\(color.css);"
        }
        if let image = fill.image {
            style += imageFillStyle(image)
        }
        return style
    }

    private mutating func imageFillStyle(_ fill: HwpDocument.ImageFill) -> String {
        let source = imageSource(fill.binID, effect: fill.effect)
        guard !source.isEmpty else {
            return ""
        }
        let placement = switch fill.mode {
        case .tile:
            "background-repeat:repeat;"
        case .stretch:
            "background-size:100% 100%;background-repeat:no-repeat;"
        case .center: 
            "background-position:center;background-repeat:no-repeat;"
        }
        return "background-image:url(\(source));\(placement)"
    }

    // MARK: Objects
    /// Half the line gap above and below an inline object: the paragraph is already moved up by half.
    private var objectGapMargins: String {
        objectGap == 0 ? "" : "margin:\(decimal(pt(objectGap / 2)))pt 0;"
    }

    private mutating func picture(_ picture: HwpDocument.Picture) -> String {
        let source = imageSource(picture.binID, effect: picture.effect)
        let size = "width:\(decimal(pt(picture.layout.width)))pt;height:\(decimal(pt(picture.layout.height)))pt;"
        var style = size
        if let line = picture.border.style {
            style += "outline:\(decimal(picture.border.width * 72 / 25.4))pt \(line.css) \(picture.border.color.css);"
        }
        _ = imageSource(picture.binID)
        var image = "<img src=\"\(source)\" style=\"\(style)display:block;\">"
        if let frame = Self.cropFrame(picture, pixels: imageSizes[picture.binID]) {
            let imageStyle = "position:absolute;max-width:none;left:\(decimal(pt(frame.x)))pt;top:\(decimal(pt(frame.y)))pt;width:\(decimal(pt(frame.width)))pt;height:\(decimal(pt(frame.height)))pt;"
            image = "<span style=\"display:block;position:relative;overflow:hidden;\(style)\"><img src=\"\(source)\" style=\"\(imageStyle)\"></span>"
        }
        if picture.layout.inline {
            return "<span style=\"display:inline-block;vertical-align:bottom;\(objectGapMargins)\">\(image)</span>"
        }
        return floating(image, layout: picture.layout)
    }

    /// Where the whole image goes, in HWPUNIT relative to the picture's box, when only part of it shows; nil when it shows whole.
    static func cropFrame(_ picture: HwpDocument.Picture, pixels: CGSize?) -> (x: Int, y: Int, width: Int, height: Int)? {
        let crop = picture.crop
        let cropWidth = crop.right - crop.left
        let cropHeight = crop.bottom - crop.top
        guard cropWidth > 0, cropHeight > 0 else {
            return nil
        }
        let full: (width: Int, height: Int) = pixels.map { (Int($0.width * 75), Int($0.height * 75)) } ?? picture.extent
        
        let slack = (width: max(full.width / 100, 75), height: max(full.height / 100, 75))
        if crop.left <= slack.width, crop.top <= slack.height, crop.right >= full.width - slack.width, crop.bottom >= full.height - slack.height {
            return nil
        }
        let whole = (width: max(full.width, crop.right), height: max(full.height, crop.bottom))
        let scaleX = Double(picture.layout.width) / Double(cropWidth)
        let scaleY = Double(picture.layout.height) / Double(cropHeight)
        return (
            Int((-Double(crop.left) * scaleX).rounded()), Int((-Double(crop.top) * scaleY).rounded()),
            Int((Double(whole.width) * scaleX).rounded()), Int((Double(whole.height) * scaleY).rounded())
        )
    }

    /// The image as a data URL, drawn in gray for 그림 효과: WebKit leaves CSS filters out of PDFs.
    private mutating func imageSource(_ id: Int, effect: HwpDocument.Picture.Effect) -> String {
        guard effect != .none else {
            return imageSource(id)
        }
        let key = ImageKey(id: id, effect: effect)
        if let cached = effectImages[key] {
            return cached
        }
        guard let item = document.binData[id], let data = try? item.data(),
              let gray = Self.grayPNG(from: data, blackAndWhite: effect == .blackAndWhite) else {
            return imageSource(id)
        }
        let source = "data:image/png;base64,\(gray.base64EncodedString())"
        effectImages[key] = source
        return source
    }

    static func grayPNG(from data: Data, blackAndWhite: Bool) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for index in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            let luma = (299 * Int(pixels[index]) + 587 * Int(pixels[index + 1]) + 114 * Int(pixels[index + 2])) / 1000
            let alpha = Int(pixels[index + 3])
            let value = UInt8(blackAndWhite ? (luma * 2 >= alpha ? alpha : 0) : luma)
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
        }
        guard let gray = context.makeImage() else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, gray, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private mutating func imageSource(_ id: Int) -> String {
        if let cached = images[id] {
            return cached
        }
        guard let item = document.binData[id], var data = try? item.data() else {
            return ""
        }
        var type = switch item.extension {
        case "jpg", "jpeg":
            "image/jpeg"
        case "png", "gif", "webp":
            "image/\(item.extension)"
        default:
            ""
        }
        // WebKit can't decode the BMPs and TIFFs Hangul often embeds; ImageIO can.
        if type.isEmpty {
            guard let png = Self.png(from: data) else {
                return ""
            }
            data = png
            type = "image/png"
        }
        let source = "data:\(type);base64,\(data.base64EncodedString())"
        images[id] = source
        if let image = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            imageSizes[id] = CGSize(width: width, height: height)
        }
        return source
    }

    static func png(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Objects not treated as characters: around the text for top-and-bottom wrapping, over or under it otherwise.
    private func floating(_ content: String, layout: HwpDocument.ObjectLayout) -> String {
        let width = "width:\(decimal(pt(layout.width)))pt;height:\(decimal(pt(layout.height)))pt;"
        if let anchor {
            let page = anchor.page
            let bodyLeft = page.left + page.gutter
            let bodyTop = page.top + page.header
            let bodyWidth = page.width - page.left - page.right - page.gutter
            let bodyHeight = page.height - bodyTop - page.bottom - page.footer
            let (referenceX, referenceWidth): (Int, Int) = switch layout.horizontal {
            case .paper:
                (0, page.width)
            case .page:
                (bodyLeft, bodyWidth)
            case .column:
                (bodyLeft + anchor.x, anchor.columnWidth)
            case .paragraph:
                (bodyLeft + anchor.x + anchor.left, anchor.columnWidth - anchor.left - anchor.right)
            }
            let (referenceY, referenceHeight): (Int, Int) = switch layout.vertical {
            case .paper:
                (0, page.height)
            case .page, .column:
                (bodyTop, bodyHeight)
            case .paragraph:
                (bodyTop + anchor.y, 0)
            }
            let x = switch layout.horizontalAlign {
            case 1:
                referenceX + (referenceWidth - layout.width) / 2 + layout.x
            case 2:
                referenceX + referenceWidth - layout.width - layout.x
            default:
                referenceX + layout.x
            }
            let y = switch layout.verticalAlign {
            case 1:
                referenceY + (referenceHeight - layout.height) / 2 + layout.y
            case 2:
                referenceY + referenceHeight - layout.height - layout.y
            default:
                referenceY + layout.y
            }
            let left = x - bodyLeft - anchor.x
            let top = y - bodyTop - anchor.y
            let z = layout.wrap == .behindText ? -1 : 1
            return "<span style=\"position:absolute;left:\(decimal(pt(left)))pt;top:\(decimal(pt(top)))pt;\(width)z-index:\(z);text-indent:0;line-height:normal;\">\(content)</span>"
        }
        switch layout.wrap {
        case .topAndBottom:
            var style = "display:block;\(width)"
            switch layout.horizontalAlign {
            case 1: 
                style += "margin-left:auto;margin-right:auto;"
            case 2: 
                style += "margin-left:auto;"
            default:
                if layout.x != 0 {
                    style += "margin-left:\(decimal(pt(layout.x)))pt;"
                }
            }
            if layout.y != 0 {
                style += "margin-top:\(decimal(pt(layout.y)))pt;"
            }
            return "<span style=\"\(style)\">\(content)</span>"
        default:
            let z = layout.wrap == .behindText ? -1 : 1
            return "<span style=\"position:absolute;left:\(decimal(pt(layout.x)))pt;top:\(decimal(pt(layout.y)))pt;\(width)z-index:\(z);text-indent:0;\">\(content)</span>"
        }
    }

    private mutating func shape(_ shape: HwpDocument.Shape) -> String {
        let width = pt(shape.layout.width)
        let height = pt(shape.layout.height)
        var inner = ""
        switch shape.kind {
        case .line:
            if let line = shape.line.style {
                let stroke = decimal(max(shape.line.width * 72 / 25.4, 0.5))
                let dash = line == .solid ? "" : " stroke-dasharray=\"3 2\""
                inner = "<svg width=\"\(decimal(width))pt\" height=\"\(decimal(height))pt\" viewBox=\"0 0 \(max(shape.layout.width, 1)) \(max(shape.layout.height, 1))\" preserveAspectRatio=\"none\" style=\"overflow:visible;display:block\"><line x1=\"\(shape.start.x)\" y1=\"\(shape.start.y)\" x2=\"\(shape.end.x)\" y2=\"\(shape.end.y)\" stroke=\"\(shape.line.color.css)\" stroke-width=\"\(stroke)pt\" vector-effect=\"non-scaling-stroke\"\(dash)/></svg>"
            }
        case .rectangle, .ellipse, .other:
            var style = "box-sizing:border-box;width:\(decimal(width))pt;height:\(decimal(height))pt;display:flex;flex-direction:column;"
            if let line = shape.line.style {
                style += "border:\(decimal(max(shape.line.width * 72 / 25.4, 0.5)))pt \(line.css) \(shape.line.color.css);"
            }
            if let fill = shape.fill {
                style += "background:\(fill.css);"
            }
            if let image = shape.image {
                style += imageFillStyle(image)
            }
            if shape.kind == .ellipse {
                style += "border-radius:50%;"
            }
            if shape.cornerRatio > 0 {
                style += "border-radius:\(decimal(min(width, height) * Double(shape.cornerRatio) / 100))pt;"
            }
            let padding = shape.textPadding
            style += "padding:\(decimal(pt(padding.top)))pt \(decimal(pt(padding.right)))pt \(decimal(pt(padding.bottom)))pt \(decimal(pt(padding.left)))pt;"
            style += "justify-content:\(["flex-start", "center", "flex-end"][min(shape.textVerticalAlign, 2)]);"
            let text = list(shape.text)
            let children = shape.children.map { child -> String in
                switch child {
                case .shape(let nested):
                    return self.shape(nested)
                case .picture(let picture):
                    return self.picture(picture)
                default: 
                    return ""
                }
            }.joined()
            inner = "<div style=\"\(style)\">\(text)</div>\(children)"
        }
        if shape.layout.inline {
            return "<span style=\"display:inline-block;position:relative;vertical-align:bottom;text-indent:0;\(objectGapMargins)\">\(inner)</span>"
        }
        return floating(inner, layout: shape.layout)
    }

    /// An equation as MathML, in a box of Hangul's width so the text after it stays where Hangul put it.
    private func equation(_ equation: HwpDocument.Equation) -> String {
        let size = decimal(pt(equation.fontSize))
        let color = equation.color == .black ? "" : "color:\(equation.color.css);"
        let width = equation.layout.width > 0 ? "width:\(decimal(pt(equation.layout.width)))pt;" : ""
        return "<span class=\"equation\" style=\"display:inline-block;\(width)text-indent:0;white-space:nowrap;font-size:\(size)pt;line-height:normal;\(color)\">\(HwpEquation.mathML(equation.script))</span>"
    }

    // MARK: HTML
    private func pt(_ value: Int) -> Double { Double(value) / 100 }

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&":
                result += "&amp;"
            case "<":
                result += "&lt;"
            case ">": 
                result += "&gt;"
            case "\"":
                result += "&quot;"
            default:
                result.append(character)
            }
        }
        return result
    }

    static let bleed = 4.0
    static let tightestSpacing = 0.08

    /// Squeezes lines that Hangul fit and the substitute faces don't, by tightening their spacing.
    static let fitLines = """
        // Tabs: advance to the next stop past the text before them, aligning what follows.
        const PX = 4 / 3;
        for (const tab of document.querySelectorAll('span.tab')) {
            const paragraph = tab.closest('.p');
            if (!paragraph || paragraph.offsetWidth === 0) continue;
            const box = paragraph.getBoundingClientRect();
            const zoom = box.width / paragraph.offsetWidth || 1;
            const style = getComputedStyle(paragraph);
            const contentLeft = box.left + (parseFloat(style.paddingLeft) + parseFloat(style.borderLeftWidth)) * zoom;
            const contentRight = box.right - (parseFloat(style.paddingRight) + parseFloat(style.borderRightWidth)) * zoom;
            const origin = contentLeft + parseFloat(tab.dataset.origin) * PX * zoom;
            const toPoints = x => (x - origin) / zoom / PX;
            const here = toPoints(tab.getBoundingClientRect().left);
            const stops = (tab.dataset.stops || '').split(',').filter(Boolean).map(item => {
                const [position, kind, leader] = item.split(':');
                return { position: parseFloat(position), kind, leader: leader === '1' };
            });
            let stop = stops.find(candidate => candidate.position > here + 0.5);
            if (!stop && tab.dataset.end) stop = { position: toPoints(contentRight), kind: 'r', leader: false };
            if (!stop) {
                const step = parseFloat(tab.dataset.default) || 40;
                stop = { position: (Math.floor(here / step + 0.001) + 1) * step, kind: 'l', leader: false };
            }
            let width = stop.position - here;
            if (stop.kind !== 'l') {
                // What follows the tab on its line, up to the next tab.
                const range = document.createRange();
                range.setStartAfter(tab);
                const container = tab.closest('.line') || paragraph;
                range.setEnd(container, container.childNodes.length);
                const next = [...container.querySelectorAll('span.tab')].find(other => tab.compareDocumentPosition(other) & Node.DOCUMENT_POSITION_FOLLOWING);
                if (next) range.setEndBefore(next);
                const top = tab.getBoundingClientRect().top;
                const rects = [...range.getClientRects()].filter(rect => rect.width > 0 && Math.abs(rect.top - top) < 40 * zoom);
                const following = rects.length ? (Math.max(...rects.map(r => r.right)) - Math.min(...rects.map(r => r.left))) / zoom / PX : 0;
                width -= stop.kind === 'r' ? following : following / 2;
            }
            tab.style.display = 'inline-block';
            tab.style.width = Math.max(width, 0) * PX + 'px';
            if (stop.leader && width > 2) {
                tab.style.overflow = 'hidden';
                tab.style.whiteSpace = 'nowrap';
                tab.style.verticalAlign = 'bottom';
                tab.style.textAlign = 'right';
                tab.textContent = '·'.repeat(Math.ceil(width / 2.5));
                tab.style.letterSpacing = '0';
                tab.style.lineHeight = 'normal';
            }
        }
        // Lines: squeeze those that Hangul fit and the stand-in faces don't, by tightening their
        // spacing while the glyphs stay apart, and past that by narrowing the glyphs, as a
        // condensed face or 장평 would.
        for (const line of document.querySelectorAll('.line')) {
            const over = line.scrollWidth - line.clientWidth;
            if (over <= 0.5) continue;
            const spans = [...line.querySelectorAll(':scope > span')];
            let characters = 0;
            for (const span of spans) characters += span.textContent.length;
            if (characters === 0) continue;
            const step = over / characters;
            // A few characters, like a list number in a narrow cell, just tighten.
            const mayNarrow = line.textContent.replace(/\\u200B/g, '').trim().length > 3;
            let narrow = false;
            for (const span of spans) {
                const style = getComputedStyle(span);
                const current = parseFloat(style.letterSpacing) || 0;
                const tightest = -\(tightestSpacing) * parseFloat(style.fontSize);
                if (!mayNarrow || current - step >= tightest) {
                    span.style.letterSpacing = (current - step) + 'px';
                    continue;
                }
                narrow = true;
                span.style.letterSpacing = Math.min(current, tightest) + 'px';
            }
            const left = line.scrollWidth - line.clientWidth;
            if (narrow && left > 0.5) {
                line.style.transformOrigin = '0 50%';
                line.style.transform = 'scaleX(' + (line.clientWidth / line.scrollWidth) + ')';
            }
        }
        """

    static func htmlPage(_ body: String, bleed: Double = bleed) -> String {
        let fontFaces = HwpFonts.Bundled.allCases.filter { body.contains($0.cssFamily) }.map(\.fontFaces).joined(separator: "\n")
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        \(fontFaces)
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        body { margin: 0; }
        body { padding: 0 \(decimal(bleed))pt; overflow-x: clip; }
        /* Not <p>: the HTML parser ends a paragraph at a <table> or <div> inside it. */
        .p { margin: 0; position: relative; white-space: pre-wrap; overflow-wrap: break-word; line-height: 0; tab-size: 40pt; text-align-last: auto; }
        .line { display: block; white-space: pre; }
        table { border-collapse: collapse; table-layout: fixed; }
        td { overflow-wrap: anywhere; }
        img { vertical-align: bottom; }
        math { font-family: 'STIX Two Math', math; }
        </style></head><body>
        \(body)</body></html>
        """
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
