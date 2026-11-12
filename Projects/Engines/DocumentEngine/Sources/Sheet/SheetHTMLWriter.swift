import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A sheet as HTML pages laid out the way Excel prints it: the print area (or the used range)
/// with its column widths, row heights, merged cells, fonts, fills, borders and alignment, and
/// the pictures, charts and text boxes over it. Hidden rows and columns stay out.
///
/// Pages are decided here rather than by WebKit: each is its own block, so a picture can be
/// placed by its cells, title rows can repeat, and a long sheet can be printed a few pages at a
/// time, since WebKit's printing slows down with the square of a document's length.
///
/// A sheet wider than its page shrinks to fit by multiplying every size rather than with CSS
/// `zoom`: WebKit keeps zoomed text at 9px or more, so a sheet zoomed small would print its text
/// too big for its cells.
struct SheetHTMLWriter {
    /// How a sheet falls onto pages. Sizes are in points before shrinking by `zoom`.
    struct Layout {
        struct Page: Hashable {
            /// Indexes into `rowBands` and `columnBands`.
            var rowBand: Int
            var columnBand: Int
        }

        var page: PagedPDFRenderer.PageSetup
        var zoom: Double
        var rows: [Int]
        var columns: [Int]
        var widths: [Double]
        /// Runs of `rows` that fit a page's height, and of `columns` that fit its width, as indexes.
        var rowBands: [Range<Int>]
        var columnBands: [Range<Int>]
        /// In print order: down then across, as Excel does unless told otherwise.
        var pages: [Page]
        /// Rows repeated at the top of every page below the first.
        var titleRows: [Int]
        var drawings: [PlacedDrawing]

        var pageCount: Int {
            pages.count
        }

        func rows(onPage page: Int) -> ArraySlice<Int> {
            rows[rowBands[pages[page].rowBand]]
        }

        func columns(onPage page: Int) -> ArraySlice<Int> {
            columns[columnBands[pages[page].columnBand]]
        }

        func widths(onPage page: Int) -> ArraySlice<Double> {
            widths[columnBands[pages[page].columnBand]]
        }

        func pageIndex(rowBand: Int, columnBand: Int) -> Int? {
            pages.firstIndex(of: Page(rowBand: rowBand, columnBand: columnBand))
        }
    }

    /// A drawing, or the part of it on one page.
    struct PlacedDrawing {
        var drawing: XLSXDrawing
        var page: Int
        /// The page's part of the sheet the drawing shows through: its cells, below any title rows.
        var window: CGRect
        /// The whole drawing, from the window's top left.
        var frame: CGRect
    }

    let workbook: XLSXWorkbook

    static let imageTypes = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "bmp": "image/bmp",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "svg": "image/svg+xml",
    ]

    /// Excel's column widths count the widest digit of the default font: seven pixels at 11pt
    /// for Calibri, eight for the Korean faces, which is why a Korean Excel's columns are wider.
    private var digitWidth: Double {
        let font = workbook.defaultFont
        let korean = ["맑은 고딕", "Malgun", "굴림", "Gulim", "돋움", "Dotum", "바탕", "Batang", "궁서", "Gungsuh", "나눔", "Nanum"]
            .contains { font.name.contains($0) }
        return (korean ? 8 : 7) * font.size / 11
    }

    // MARK: Layout

    /// The sheet's pages, or nil when it has nothing to print.
    func layout(for sheet: XLSXWorkbook.Sheet) -> Layout? {
        guard let range = sheet.printArea ?? usedRange(sheet) else {
            return nil
        }
        let rows = range.rows.filter { !sheet.hiddenRows.contains($0) }
        let columns = range.columns.filter { !sheet.hiddenColumns.contains($0) }
        guard !rows.isEmpty, !columns.isEmpty else {
            return nil
        }
        let widths = columns.map { columnWidth($0, in: sheet) }
        let tableWidth = widths.reduce(0, +)
        let tableHeight = rows.reduce(0) { $0 + rowHeight($1, in: sheet) }
        let portrait = pageSetup(
            sheet.page,
            landscape: false
        )
        let landscape = pageSetup(
            sheet.page,
            landscape: true
        )
        func contentWidth(_ page: PagedPDFRenderer.PageSetup) -> Double {
            page.paperSize.width - page.margins.left - page.margins.right
        }
        // Excel writes "portrait" into most files whether chosen or not, so only landscape is
        // taken as a choice; a sheet too wide standing up may turn.
        var page = sheet.page.landscape == true ? landscape : portrait
        var zoom = Double(sheet.page.scale) / 100
        if sheet.page.fitsToPages {
            if sheet.page.landscape == nil, tableWidth > contentWidth(portrait) {
                page = landscape
            }
            zoom = 1
            if sheet.page.pagesWide > 0 {
                zoom = min(zoom, contentWidth(page) * Double(sheet.page.pagesWide) / tableWidth)
            }
            if sheet.page.pagesTall > 0 {
                let contentHeight = page.paperSize.height - page.margins.top - page.margins.bottom
                zoom = min(zoom, contentHeight * Self.pageFill * Double(sheet.page.pagesTall) / tableHeight)
            }
        } else if tableWidth * zoom > contentWidth(page) {
            // A little too wide: shrinking reads better than a page holding a column or two.
            let fits = [page, landscape].first { contentWidth($0) / (tableWidth * zoom) >= Self.smallestFit }
            if let fits {
                page = fits
                zoom = contentWidth(fits) / tableWidth
            } else if sheet.page.landscape == nil {
                page = landscape
            }
        }
        zoom = max(zoom, 0.05)
        let contentHeight = page.paperSize.height - page.margins.top - page.margins.bottom

        let titleRows = sheet.titleRows.map { titles in rows.filter { titles.contains($0) } } ?? []
        let rowStarts = paginate(
            rows: rows,
            sheet: sheet,
            pageHeight: contentHeight / zoom * Self.pageFill,
            titleRows: titleRows
        )
        let rowBands = rowStarts.indices.map { index in
            rowStarts[index]..<(index + 1 < rowStarts.count ? rowStarts[index + 1] : rows.count)
        }
        let columnBands = Self.bands(
            widths,
            limit: contentWidth(page) / zoom + 0.5
        )
        let order: [Layout.Page] = sheet.page.acrossFirst
            ? rowBands.indices.flatMap { row in columnBands.indices.map { Layout.Page(rowBand: row, columnBand: $0) } }
            : columnBands.indices.flatMap { column in rowBands.indices.map { Layout.Page(rowBand: $0, columnBand: column) } }
        let titleHeight = titleRows.reduce(0) { $0 + rowHeight($1, in: sheet) }
        let pieces = sheet.drawings.flatMap { drawing in
            self.pieces(
                of: drawing,
                rows: rows,
                columns: columns,
                widths: widths,
                rowBands: rowBands,
                columnBands: columnBands,
                titleHeight: titleHeight,
                sheet: sheet
            )
        }
        // Excel leaves out pages with nothing on them.
        let drawn = Set(pieces.map(\.page))
        let pages = order.filter { page in
            drawn.contains(page) || hasContent(
                rows: rows[rowBands[page.rowBand]],
                columns: columns[columnBands[page.columnBand]],
                sheet: sheet
            )
        }
        var layout = Layout(
            page: page,
            zoom: zoom,
            rows: rows,
            columns: columns,
            widths: widths,
            rowBands: rowBands,
            columnBands: columnBands,
            pages: pages,
            titleRows: titleRows,
            drawings: []
        )
        layout.drawings = pieces.compactMap { piece in
            layout.pageIndex(rowBand: piece.page.rowBand, columnBand: piece.page.columnBand).map { page in
                PlacedDrawing(
                    drawing: piece.drawing,
                    page: page,
                    window: piece.window,
                    frame: piece.frame
                )
            }
        }
        return layout
    }

    /// Whether a cell shows anything on paper: a value, a border, or a fill other than white,
    /// which Google Sheets puts on every cell it exports.
    private func shows(_ cell: XLSXWorkbook.Cell) -> Bool {
        guard cell.text.isEmpty else {
            return true
        }
        guard workbook.styles.indices.contains(cell.style) else {
            return false
        }
        let style = workbook.styles[cell.style]
        let fill = style.fill.map { $0.uppercased() != "#FFFFFF" } ?? false
        return fill || !style.borders.isEmpty
    }

    /// Whether any of these cells shows a value, fill or border.
    private func hasContent(
        rows: ArraySlice<Int>,
        columns: ArraySlice<Int>,
        sheet: XLSXWorkbook.Sheet
    ) -> Bool {
        let columnSet = Set(columns)
        for row in rows {
            for (column, cell) in sheet.cells[row] ?? [:] where columnSet.contains(column) && shows(cell) {
                return true
            }
        }
        return false
    }

    /// How much of a page's height rows fill, leaving room for rows that print a little taller.
    static let pageFill = 0.98

    /// How far a sheet a little wider than its page shrinks to fit; wider ones split across pages.
    static let smallestFit = 0.6

    /// Runs of columns that fit `limit`, a column too wide for any page on one of its own.
    private static func bands(_ widths: [Double], limit: Double) -> [Range<Int>] {
        var bands: [Range<Int>] = []
        var start = 0
        var used = 0.0
        for (index, width) in widths.enumerated() {
            if index > start, used + width > limit {
                bands.append(start..<index)
                start = index
                used = 0
            }
            used += width
        }
        bands.append(start..<widths.count)
        return bands
    }

    /// Where each page starts: when the next row would overflow it, at a manual break, and
    /// never inside merged cells that fit on one page.
    private func paginate(
        rows: [Int],
        sheet: XLSXWorkbook.Sheet,
        pageHeight: Double,
        titleRows: [Int]
    ) -> [Int] {
        let titleHeight = titleRows.reduce(0) { $0 + rowHeight($1, in: sheet) }
        var mergeTops: [Int: Int] = [:]
        for merge in sheet.merges where merge.bottom > merge.top {
            for row in (merge.top + 1)...merge.bottom {
                mergeTops[row] = min(mergeTops[row] ?? merge.top, merge.top)
            }
        }
        let positions = Dictionary(
            rows.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var starts = [0]
        var used = 0.0
        for (index, row) in rows.enumerated() {
            let height = rowHeight(row, in: sheet)
            let start = starts[starts.count - 1]
            let repeatsTitles = starts.count > 1 && !titleRows.contains(row)
            let available = pageHeight - (repeatsTitles ? titleHeight : 0)
            let isManualBreak = sheet.pageBreaks.contains(row)
            guard index > start, isManualBreak || used + height > available else {
                used += height
                continue
            }
            var newStart = index
            if !isManualBreak,
               let top = mergeTops[row],
               let topIndex = positions[top] ?? rows.firstIndex(where: { $0 >= top }),
               topIndex > start {
                newStart = topIndex
            }
            starts.append(newStart)
            used = rows[newStart...index].reduce(0) { $0 + rowHeight($1, in: sheet) }
        }
        return starts
    }

    /// Consecutive pages to print together, about `cellsPerChunk` cells at a time.
    func chunks(_ layout: Layout, cellsPerChunk: Int = 20_000) -> [Range<Int>] {
        var chunks: [Range<Int>] = []
        var start = 0
        var cells = 0
        for page in 0..<layout.pageCount {
            cells += layout.rows(onPage: page).count * layout.columns(onPage: page).count
            let next = page + 1
            if next == layout.pageCount || cells >= cellsPerChunk {
                chunks.append(start..<next)
                start = next
                cells = 0
            }
        }
        return chunks
    }

    /// The rows and columns from the first to the last cell with a value, fill or border, and
    /// any drawing over the sheet.
    private func usedRange(_ sheet: XLSXWorkbook.Sheet) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        var top = Int.max
        var left = Int.max
        var bottom = -1
        var right = -1
        func include(_ row: Int, _ column: Int) {
            top = min(top, row)
            left = min(left, column)
            bottom = max(bottom, row)
            right = max(right, column)
        }
        for (row, cells) in sheet.cells {
            for (column, cell) in cells {
                if shows(cell) {
                    include(row, column)
                }
            }
        }
        for drawing in sheet.drawings {
            let corners = extent(of: drawing, in: sheet)
            include(corners.from.row, corners.from.column)
            include(corners.to.row, corners.to.column)
        }
        guard bottom >= 0 else {
            return nil
        }
        for merge in sheet.merges where merge.top <= bottom && merge.left <= right && merge.bottom >= top && merge.right >= left {
            include(merge.top, merge.left)
            include(merge.bottom, merge.right)
        }
        return (top...bottom, left...right)
    }

    /// The cells a drawing's corners fall in.
    private func extent(
        of drawing: XLSXDrawing,
        in sheet: XLSXWorkbook.Sheet
    ) -> (from: XLSXDrawing.Marker, to: XLSXDrawing.Marker) {
        switch drawing.placement {
        case .between(let from, let to):
            return (from, to)
        case .sized(let from, let size):
            var column = from.column
            var remaining = from.columnOffset + size.width
            while remaining > columnWidth(column, in: sheet), column < 16_383 {
                remaining -= sheet.hiddenColumns.contains(column) ? 0 : columnWidth(column, in: sheet)
                column += 1
            }
            var row = from.row
            remaining = from.rowOffset + size.height
            while remaining > rowHeight(row, in: sheet), row < 1_048_575 {
                remaining -= sheet.hiddenRows.contains(row) ? 0 : rowHeight(row, in: sheet)
                row += 1
            }
            return (from, XLSXDrawing.Marker(row: row, column: column))
        }
    }

    /// A drawing on each page it reaches: Excel cuts one that crosses a page break and goes on
    /// with it on the next page.
    private func pieces(
        of drawing: XLSXDrawing,
        rows: [Int],
        columns: [Int],
        widths: [Double],
        rowBands: [Range<Int>],
        columnBands: [Range<Int>],
        titleHeight: Double,
        sheet: XLSXWorkbook.Sheet
    ) -> [(drawing: XLSXDrawing, page: Layout.Page, window: CGRect, frame: CGRect)] {
        let heights = rows.map { rowHeight($0, in: sheet) }
        // Positions in the printed sheet, from the top left of its first cell.
        func x(_ marker: XLSXDrawing.Marker) -> Double {
            let before = zip(columns, widths)
                .filter { $0.0 < marker.column }
                .reduce(0) { $0 + $1.1 }
            let isShown = columns.contains(marker.column)
            return before + (isShown ? marker.columnOffset : 0)
        }
        func y(_ marker: XLSXDrawing.Marker) -> Double {
            let before = zip(rows, heights)
                .filter { $0.0 < marker.row }
                .reduce(0) { $0 + $1.1 }
            let isShown = rows.contains(marker.row)
            return before + (isShown ? marker.rowOffset : 0)
        }
        let frame: CGRect
        switch drawing.placement {
        case .between(let from, let to):
            frame = CGRect(
                x: x(from),
                y: y(from),
                width: max(x(to) - x(from), 1),
                height: max(y(to) - y(from), 1)
            )
        case .sized(let from, let size):
            frame = CGRect(
                origin: CGPoint(x: x(from), y: y(from)),
                size: size
            )
        }

        var pieces: [(drawing: XLSXDrawing, page: Layout.Page, window: CGRect, frame: CGRect)] = []
        for (rowBand, rowRange) in rowBands.enumerated() {
            let top = heights[..<rowRange.lowerBound].reduce(0, +)
            let height = heights[rowRange].reduce(0, +)
            for (columnBand, columnRange) in columnBands.enumerated() {
                let left = widths[..<columnRange.lowerBound].reduce(0, +)
                let width = widths[columnRange].reduce(0, +)
                let band = CGRect(
                    x: left,
                    y: top,
                    width: width,
                    height: height
                )
                guard band.intersects(frame) else {
                    continue
                }
                pieces.append(
                    (
                        drawing: drawing,
                        page: Layout.Page(rowBand: rowBand, columnBand: columnBand),
                        window: CGRect(
                            x: 0,
                            y: rowBand > 0 ? titleHeight : 0,
                            width: width,
                            height: height
                        ),
                        frame: frame.offsetBy(dx: -left, dy: -top)
                    )
                )
            }
        }
        return pieces
    }

    /// A page's rows as printed: title rows first on every page below the first.
    private func renderedRows(onPage page: Int, in layout: Layout) -> [Int] {
        let rows = Array(layout.rows(onPage: page))
        guard layout.pages[page].rowBand > 0, !layout.titleRows.isEmpty else {
            return rows
        }
        return layout.titleRows.filter { !rows.contains($0) } + rows
    }

    private func columnWidth(_ column: Int, in sheet: XLSXWorkbook.Sheet) -> Double {
        // Pixels to points.
        ((sheet.columnWidths[column] ?? sheet.defaultColumnWidth) * digitWidth).rounded() * 0.75
    }

    private func rowHeight(_ row: Int, in sheet: XLSXWorkbook.Sheet) -> Double {
        sheet.rowHeights[row] ?? sheet.defaultRowHeight
    }

    /// The sheet's paper and margins, standing up or turned sideways.
    private func pageSetup(_ setup: XLSXWorkbook.PageSetup, landscape: Bool) -> PagedPDFRenderer.PageSetup {
        let paper: CGSize = switch setup.paper {
        case 1:
            CGSize(width: 612, height: 792)
        case 5:
            CGSize(width: 612, height: 1008)
        case 8:
            CGSize(width: 841.89, height: 1190.55)
        case 11:
            CGSize(width: 419.53, height: 595.28)
        default:
            PagedPDFRenderer.PageSetup.a4.paperSize
        }
        let margins = PagedPDFRenderer.PageSetup.Margins(
            top: setup.margins.top * 72,
            left: setup.margins.left * 72,
            bottom: setup.margins.bottom * 72,
            right: setup.margins.right * 72
        )
        return PagedPDFRenderer.PageSetup(
            paperSize: landscape ? CGSize(width: paper.height, height: paper.width) : paper,
            margins: margins
        )
    }

    // MARK: HTML

    /// The pages in `pages`, each starting a new sheet of paper.
    func html(
        for sheet: XLSXWorkbook.Sheet,
        layout: Layout,
        pages: Range<Int>
    ) -> String {
        let zoom = layout.zoom
        var body = ""
        for page in pages {
            let rows = renderedRows(onPage: page, in: layout)
            let widths = layout.widths(onPage: page)
            let columnGroup = widths
                .map { "<col style=\"width:\(Self.number($0 * zoom))pt\">" }
                .joined()
            var style = "width:\(Self.number(widths.reduce(0, +) * zoom))pt"
            if page != pages.lowerBound {
                style += ";break-before:page"
            }
            body += "<div class=\"page\" style=\"\(style)\">"
            body += "<table><colgroup>\(columnGroup)</colgroup><tbody>"
            body += tableRows(
                rows,
                columns: Array(layout.columns(onPage: page)),
                sheet: sheet,
                layout: layout
            )
            body += "</tbody></table>"
            for placed in layout.drawings where placed.page == page {
                let window = CGRect(
                    x: placed.window.minX * zoom,
                    y: placed.window.minY * zoom,
                    width: placed.window.width * zoom,
                    height: placed.window.height * zoom
                )
                body += "<div class=\"window\" style=\"\(Self.position(window))\">"
                body += drawing(
                    placed,
                    zoom: zoom
                )
                body += "</div>"
            }
            body += "</div>"
        }

        let font = workbook.defaultFont
        return """
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
            body { margin: 0; }
            .page {
                position: relative;
            }
            table {
                border-collapse: collapse;
                table-layout: fixed;
                width: 100%;
                font-family: \(Self.fontFamily(font.name));
                font-size: \(Self.number(font.size * zoom))pt;
                color: #000;
            }
            td {
                padding: 0 \(Self.number(1.5 * zoom))pt;
                overflow: hidden;
                white-space: pre;
                vertical-align: bottom;
                line-height: 1.15;
                \(sheet.page.gridLines ? "border: 0.5pt solid #BFBFBF;" : "")
            }
            .spill { overflow: visible; }
            .left { text-align: left; }
            .center { text-align: center; }
            .right { text-align: right; }
            .window {
                position: absolute;
                overflow: hidden;
                z-index: 1;
            }
            .drawing {
                position: absolute;
            }
            .item {
                position: absolute;
                box-sizing: border-box;
            }
            .item img {
                display: block;
                image-orientation: none;
            }
            \(styleSheet(scale: zoom))
            </style>
            </head>
            <body>
            \(body)
            </body>
            </html>
            """
    }

    private func tableRows(
        _ rows: [Int],
        columns: [Int],
        sheet: XLSXWorkbook.Sheet,
        layout: Layout
    ) -> String {
        // Merged cells start at their first row on this page, so a merge split by a page break
        // shows on both sides.
        var starts: [[Int]: (merge: XLSXWorkbook.Sheet.Merge, rowSpan: Int, columnSpan: Int)] = [:]
        var covered: Set<[Int]> = []
        for merge in sheet.merges {
            let positions = rows.indices.filter { (merge.top...merge.bottom).contains(rows[$0]) }
            let spanned = columns.filter { (merge.left...merge.right).contains($0) }
            guard let first = positions.first, let left = spanned.first else {
                continue
            }
            starts[[first, left]] = (merge, positions.count, spanned.count)
            for position in positions {
                for column in spanned where [position, column] != [first, left] {
                    covered.insert([position, column])
                }
            }
        }

        var html = ""
        for (position, row) in rows.enumerated() {
            let height = rowHeight(row, in: sheet) * layout.zoom
            html += "<tr style=\"height:\(Self.number(height))pt\">"
            for (index, column) in columns.enumerated() where !covered.contains([position, column]) {
                var attributes = ""
                var cell = sheet.cells[row]?[column]
                let merge = starts[[position, column]]
                if let merge {
                    if merge.columnSpan > 1 {
                        attributes += " colspan=\"\(merge.columnSpan)\""
                    }
                    if merge.rowSpan > 1 {
                        attributes += " rowspan=\"\(merge.rowSpan)\""
                    }
                    cell = sheet.cells[merge.merge.top]?[merge.merge.left] ?? cell
                }
                guard let cell else {
                    html += "<td\(attributes)></td>"
                    continue
                }
                let style = workbook.styles.indices.contains(cell.style) ? workbook.styles[cell.style] : XLSXWorkbook.Style()
                var classes = "s\(cell.style) " + Self.defaultAlignment(cell, style: style)
                // Text that doesn't wrap runs on over an empty neighbor, as in Excel.
                let next = index + 1 < columns.count ? columns[index + 1] : nil
                let neighborIsEmpty = next.map { (sheet.cells[row]?[$0]?.text ?? "").isEmpty } ?? true
                if !style.wraps, cell.kind == .text, neighborIsEmpty, merge == nil {
                    classes += " spill"
                }
                var content = Self.escape(cell.text)
                if cell.kind == .number {
                    classes += " num"
                    content = "<span data-size=\"\(Self.number(style.font.size * layout.zoom))\">\(content)</span>"
                }
                html += "<td class=\"\(classes)\"\(attributes)>\(content)</td>"
            }
            html += "</tr>"
        }
        return html
    }

    // MARK: Drawings

    private func drawing(_ placed: PlacedDrawing, zoom: Double) -> String {
        let box = CGRect(
            x: placed.frame.minX * zoom,
            y: placed.frame.minY * zoom,
            width: placed.frame.width * zoom,
            height: placed.frame.height * zoom
        )
        // Laid out at the window's top and moved down only as painted: WebKit pushes a picture
        // whose box crosses a page break onto the next page, even where the window cuts it off.
        let laidOut = CGRect(
            x: box.minX,
            y: 0,
            width: box.width,
            height: box.height
        )
        var html = "<div class=\"drawing\" style=\"\(Self.position(laidOut));transform:translateY(\(Self.number(box.minY))pt)\">"
        for item in placed.drawing.items {
            var frame = CGRect(
                x: item.frame.minX * box.width,
                y: item.frame.minY * box.height,
                width: item.frame.width * box.width,
                height: item.frame.height * box.height
            )
            // A turned object keeps its own size, centered on the box its cells give.
            if placed.drawing.items.count == 1, item.rotation != 0, let size = placed.drawing.size {
                let width = size.width * zoom
                let height = size.height * zoom
                frame = CGRect(
                    x: (box.width - width) / 2,
                    y: (box.height - height) / 2,
                    width: width,
                    height: height
                )
            }
            var transforms: [String] = []
            if item.rotation != 0 {
                transforms.append("rotate(\(Self.number(item.rotation))deg)")
            }
            if item.flipsHorizontally {
                transforms.append("scaleX(-1)")
            }
            if item.flipsVertically {
                transforms.append("scaleY(-1)")
            }
            var style = Self.position(frame)
            if !transforms.isEmpty {
                style += ";transform:\(transforms.joined(separator: " "))"
            }
            let content = itemContent(
                item.content,
                size: frame.size,
                zoom: zoom
            )
            html += "<div class=\"item\" style=\"\(style)\">\(content)</div>"
        }
        return html + "</div>"
    }

    private func itemContent(
        _ content: XLSXDrawing.Content,
        size: CGSize,
        zoom: Double
    ) -> String {
        switch content {
        case .picture(let picture):
            return Self.pictureHTML(
                picture,
                size: size
            )
        case .chart(let chart):
            let writer = ChartSVGWriter(
                chart: chart,
                size: CGSize(
                    width: size.width / zoom,
                    height: size.height / zoom
                ),
                fontName: workbook.defaultFont.name,
                formats: workbook.formats
            )
            return writer.svg()
        case .shape(let shape):
            return shapeHTML(
                shape,
                size: size,
                zoom: zoom
            )
        case .line(let color, let width):
            // Drawn corner to corner; flips turn it the other way.
            let stroke = max(width * zoom, 0.5) * 4 / 3
            return """
                <svg width="100%" height="100%" viewBox="0 0 100 100" preserveAspectRatio="none" style="overflow:visible;display:block">\
                <line x1="0" y1="0" x2="100" y2="100" stroke="\(color)" stroke-width="\(Self.number(stroke))" vector-effect="non-scaling-stroke"/></svg>
                """
        case .chartPart:
            return ""
        }
    }

    /// A picture filling its box: cropped as the drawing says, and no larger than the page needs.
    private static func pictureHTML(_ picture: XLSXDrawing.Picture, size: CGSize) -> String {
        let crop = picture.crop
        let keptWidth = max(1 - crop.left - crop.right, 0.01)
        let keptHeight = max(1 - crop.top - crop.bottom, 0.01)
        // About 200 pixels an inch of the printed size.
        let pixels = max(size.width / keptWidth, size.height / keptHeight) * 3
        let source = imageURI(
            picture,
            maximumPixels: pixels
        )
        let isCropped = crop.left != 0 || crop.top != 0 || crop.right != 0 || crop.bottom != 0
        guard isCropped else {
            return "<img src=\"\(source)\" style=\"width:100%;height:100%\">"
        }
        let image = [
            "position:absolute",
            "max-width:none",
            "width:\(number(100 / keptWidth))%",
            "height:\(number(100 / keptHeight))%",
            "left:\(number(-100 * crop.left / keptWidth))%",
            "top:\(number(-100 * crop.top / keptHeight))%",
        ]
        return "<div style=\"position:relative;width:100%;height:100%;overflow:hidden\"><img src=\"\(source)\" style=\"\(image.joined(separator: ";"))\"></div>"
    }

    /// The picture as a `data:` URL, scaled down when it has far more pixels than the page shows.
    /// Its pixels stay as stored, without turning by EXIF orientation, as in Excel.
    private static func imageURI(_ picture: XLSXDrawing.Picture, maximumPixels: Double) -> String {
        let original = "data:\(picture.type);base64,\(picture.data.base64EncodedString())"
        let scalable = ["image/jpeg", "image/png", "image/tiff", "image/bmp"].contains(picture.type)
        guard scalable,
              let source = CGImageSourceCreateWithData(picture.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              Double(max(width, height)) > maximumPixels * 1.25
        else {
            return original
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maximumPixels), 64),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return original
        }
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return original
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            return original
        }
        let mime = hasAlpha ? "image/png" : "image/jpeg"
        return "data:\(mime);base64,\((data as Data).base64EncodedString())"
    }

    /// A text box or filled shape: its fill, outline and corners, and its paragraphs.
    private func shapeHTML(
        _ shape: XLSXDrawing.Shape,
        size: CGSize,
        zoom: Double
    ) -> String {
        let insets = [
            shape.insets.top,
            shape.insets.right,
            shape.insets.bottom,
            shape.insets.left,
        ]
        var css = [
            "width:100%",
            "height:100%",
            "box-sizing:border-box",
            "display:flex",
            "flex-direction:column",
            "overflow:hidden",
            "white-space:pre-wrap",
            "overflow-wrap:anywhere",
            "line-height:1.2",
            "font-family:\(Self.fontFamily(workbook.defaultFont.name))",
            "color:\(shape.textColor ?? "#000000")",
            "padding:" + insets.map { "\(Self.number($0 * zoom))pt" }.joined(separator: " "),
        ]
        switch shape.verticalAlignment {
        case "ctr":
            css.append("justify-content:center")
        case "b":
            css.append("justify-content:flex-end")
        default:
            css.append("justify-content:flex-start")
        }
        if let fill = shape.fill {
            css.append("background:\(fill)")
        }
        if let outline = shape.outline {
            css.append("border:\(Self.number(max(outline.width * zoom, 0.25)))pt solid \(outline.color)")
        }
        switch shape.geometry {
        case "roundRect":
            css.append("border-radius:\(Self.number(min(size.width, size.height) * 0.1667))pt")
        case "ellipse":
            css.append("border-radius:50%")
        default:
            break
        }

        var paragraphs = ""
        for paragraph in shape.paragraphs {
            let alignment = switch paragraph.alignment {
            case "ctr":
                "center"
            case "r":
                "right"
            case "just", "dist":
                "justify"
            default:
                "left"
            }
            var runs = ""
            for run in paragraph.runs {
                var style = ["font-size:\(Self.number((run.size ?? 11) * zoom))pt"]
                if run.bold {
                    style.append("font-weight:bold")
                }
                if run.italic {
                    style.append("font-style:italic")
                }
                if run.underline {
                    style.append("text-decoration:underline")
                }
                if let color = run.color {
                    style.append("color:\(color)")
                }
                runs += "<span style=\"\(style.joined(separator: ";"))\">\(Self.escape(run.text))</span>"
            }
            if paragraph.runs.isEmpty {
                // An empty paragraph still takes a line.
                runs = "<span style=\"font-size:\(Self.number(11 * zoom))pt\">\u{200B}</span>"
            }
            paragraphs += "<div style=\"text-align:\(alignment)\">\(runs)</div>"
        }
        return "<div style=\"\(css.joined(separator: ";"))\">\(paragraphs)</div>"
    }

    private static func position(_ frame: CGRect) -> String {
        [
            "left:\(number(frame.minX))pt",
            "top:\(number(frame.minY))pt",
            "width:\(number(frame.width))pt",
            "height:\(number(frame.height))pt",
        ].joined(separator: ";")
    }

    // MARK: Styles

    /// Shrinks each number too wide for its cell until it fits: Excel never cuts a number short,
    /// and the Mac's stand-in fonts run wider than Calibri. The new size is in points from the
    /// cell's own, `data-size`, since computed sizes come back zoomed by the renderer. All
    /// widths are read before any is changed, so the page is laid out once.
    static let fitNumbersScript = """
        const numbers = [...document.querySelectorAll("td.num > span")];
        const sizes = numbers.map(number => {
            const cell = number.parentElement;
            if (cell.scrollWidth <= cell.clientWidth) {
                return null;
            }
            return parseFloat(number.dataset.size) * cell.clientWidth / cell.scrollWidth * 0.95;
        });
        numbers.forEach((number, index) => {
            if (sizes[index] !== null) {
                number.style.fontSize = sizes[index] + "pt";
            }
        });
        """

    /// One class per cell style, its sizes multiplied by `scale`.
    private func styleSheet(scale: Double) -> String {
        let base = workbook.defaultFont
        return workbook.styles.enumerated().map { index, style in
            var rules: [String] = []
            let font = style.font
            if font.name != base.name {
                rules.append("font-family: \(Self.fontFamily(font.name))")
            }
            if font.size != base.size {
                rules.append("font-size: \(Self.number(font.size * scale))pt")
            }
            if font.bold {
                rules.append("font-weight: bold")
            }
            if font.italic {
                rules.append("font-style: italic")
            }
            let decorations = [
                font.underline ? "underline" : nil,
                font.strike ? "line-through" : nil,
            ].compactMap { $0 }
            if !decorations.isEmpty {
                rules.append("text-decoration: \(decorations.joined(separator: " "))")
            }
            if let color = font.color {
                rules.append("color: \(color)")
            }
            if let fill = style.fill {
                rules.append("background: \(fill)")
            }
            for (side, border) in style.borders.sorted(by: { $0.key < $1.key }) {
                rules.append("border-\(side): \(border)")
            }
            switch style.vertical {
            case "top":
                rules.append("vertical-align: top")
            case "center", "justify", "distributed":
                rules.append("vertical-align: middle")
            default:
                break
            }
            if style.wraps {
                rules.append("white-space: pre-wrap")
                rules.append("overflow-wrap: anywhere")
            }
            if style.indent > 0 {
                let indent = Double(style.indent * 3) * digitWidth * 0.75 * scale
                rules.append("padding-left: \(Self.number(indent))pt")
            }
            guard !rules.isEmpty else {
                return ""
            }
            return ".s\(index) { \(rules.joined(separator: "; ")); }"
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    /// Excel's General alignment puts text left, numbers right and TRUE or errors in the middle.
    private static func defaultAlignment(_ cell: XLSXWorkbook.Cell, style: XLSXWorkbook.Style) -> String {
        switch style.horizontal {
        case "left", "fill":
            return "left"
        case "center", "centerContinuous":
            return "center"
        case "right":
            return "right"
        case "justify", "distributed":
            return "left"
        default:
            switch cell.kind {
            case .number:
                return "right"
            case .boolean, .error:
                return "center"
            case .text:
                return "left"
            }
        }
    }

    /// The sheet's font, then a Mac face of the same kind for what it can't show.
    static func fontFamily(_ name: String) -> String {
        let serif = ["바탕", "궁서", "Batang", "Gungsuh", "Times New Roman", "Cambria", "Georgia"]
            .contains { name.contains($0) }
        let fallback = serif ? "'AppleMyungjo', serif" : "'Apple SD Gothic Neo', sans-serif"
        let quoted = name.replacingOccurrences(
            of: "'",
            with: ""
        )
        return "'\(quoted)', \(fallback)"
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func escape(_ text: String) -> String {
        HwpDocxWriter.escape(text)
    }
}
