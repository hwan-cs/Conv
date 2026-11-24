import Foundation
import ZIPFoundation

/// An .xlsx read for what a printout or a CSV needs: each sheet's cells as Excel shows them, with
/// their fonts, fills, borders and alignment, merged cells, column and row sizes, print settings,
/// and the pictures, charts and text boxes drawn over it. Comments are left out, as Excel
/// leaves them out of a printout unless asked.
struct XLSXWorkbook {
    enum ReadError: Error {
        case notAnXLSX
    }

    struct Cell: Equatable {
        enum Kind: Equatable {
            case text
            case number
            case boolean
            case error
        }

        /// As Excel shows it, with the cell's number format applied.
        var text: String
        var kind: Kind
        var style: Int
        /// The value itself, for a number: what a chart plots.
        var number: Double? = nil
    }

    struct Sheet {
        struct Merge: Equatable {
            var top: Int
            var left: Int
            var bottom: Int
            var right: Int
        }

        var name: String
        var isHidden = false
        /// Row → column → cell, both from 0.
        var cells: [Int: [Int: Cell]] = [:]
        var merges: [Merge] = []
        /// Widths in the default font's digits, padding included, as Excel stores them.
        var columnWidths: [Int: Double] = [:]
        var hiddenColumns: Set<Int> = []
        /// Heights in points.
        var rowHeights: [Int: Double] = [:]
        var hiddenRows: Set<Int> = []
        /// Excel's 64-pixel default column.
        var defaultColumnWidth = 64.0 / 7
        var defaultRowHeight = 15.0
        var page = PageSetup()
        var drawings: [XLSXDrawing] = []
        /// The rows and columns to print, when the sheet sets a print area.
        var printArea: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)?
        /// Rows printed again at the top of every page.
        var titleRows: ClosedRange<Int>?
        /// Rows that start a new page by hand.
        var pageBreaks: Set<Int> = []

        /// Values by position, with empty strings between: what a CSV of the sheet holds.
        func rows() -> [[String]] {
            let filled = cells.mapValues { row in
                row.filter { !$0.value.text.isEmpty }
            }
            guard let lastRow = filled.filter({ !$0.value.isEmpty }).keys.max() else {
                return []
            }
            let lastColumn = filled.values
                .compactMap { $0.keys.max() }
                .max() ?? 0
            return (0...lastRow).map { row in
                (0...lastColumn).map { column in
                    cells[row]?[column]?.text ?? ""
                }
            }
        }
    }

    struct PageSetup: Equatable {
        var landscape: Bool?
        /// Inches, as Excel stores them; Excel's defaults when the sheet has none.
        var margins = (top: 0.75, left: 0.7, bottom: 0.75, right: 0.7)
        var paper = 9
        var scale = 100
        /// Shrinks to fit `pagesWide` by `pagesTall` pages; zero leaves that direction free.
        var fitsToPages = false
        var pagesWide = 1
        var pagesTall = 1
        /// Prints across, then down, rather than Excel's default of down, then across.
        var acrossFirst = false
        var gridLines = false

        static func == (lhs: PageSetup, rhs: PageSetup) -> Bool {
            lhs.landscape == rhs.landscape
                && lhs.margins == rhs.margins
                && lhs.paper == rhs.paper
                && lhs.scale == rhs.scale
                && lhs.fitsToPages == rhs.fitsToPages
                && lhs.pagesWide == rhs.pagesWide
                && lhs.pagesTall == rhs.pagesTall
                && lhs.acrossFirst == rhs.acrossFirst
                && lhs.gridLines == rhs.gridLines
        }
    }

    struct Style: Equatable {
        var font = Font()
        var fill: String?
        /// CSS `border-*` values by side: "top", "left", "bottom", "right".
        var borders: [String: String] = [:]
        var horizontal: String?
        var vertical: String?
        var wraps = false
        var indent = 0
        var numberFormat = 0
    }

    struct Font: Equatable {
        var name = "Calibri"
        var size = 11.0
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var color: String?
    }

    var sheets: [Sheet] = []
    var styles: [Style] = [Style()]
    var formats = NumberFormats(
        nil,
        date1904: false
    )
    /// Index into `sheets` of the sheet open when the file was saved.
    var activeSheet = 0

    var defaultFont: Font {
        styles.first?.font ?? Font()
    }

    init(url: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(
                url: url,
                accessMode: .read
            )
        } catch {
            throw ReadError.notAnXLSX
        }
        let package = XLSXPackage(archive: archive)
        guard let workbookPath = try package.relationships(of: "").first(where: { $0.type.hasSuffix("/officeDocument") })?.path,
              let workbook = try package.xml(at: workbookPath)
        else {
            throw ReadError.notAnXLSX
        }
        let relationships = try package.relationships(of: workbookPath)
        func part(_ type: String) -> String? {
            relationships.first { $0.type.hasSuffix("/\(type)") }?.path
        }

        let theme = try DocxTheme(part("theme").flatMap { try package.xml(at: $0) })
        let colors = SpreadsheetColors(theme: theme)
        let strings = try Self.sharedStrings(part("sharedStrings").flatMap { try package.xml(at: $0) })
        let stylesheet = try part("styles").flatMap { try package.xml(at: $0) }
        styles = Self.styles(stylesheet, colors: colors)
        let formats = NumberFormats(
            stylesheet,
            date1904: workbook.sml("workbookPr")?.attributeValue("date1904").map { $0 == "1" || $0 == "true" } ?? false
        )
        self.formats = formats

        let targets = Dictionary(
            relationships.map { ($0.id, $0.path) },
            uniquingKeysWith: { first, _ in first }
        )
        // Print areas and titles are names local to a sheet, by its position in the workbook.
        var printAreas: [Int: String] = [:]
        var printTitles: [Int: String] = [:]
        for name in workbook.sml("definedNames")?.smlChildren("definedName") ?? [] {
            guard let index = name.attributeValue("localSheetId").flatMap(Int.init),
                  let value = name.stringValue
            else {
                continue
            }
            switch name.attributeValue("name") {
            case "_xlnm.Print_Area":
                printAreas[index] = value
            case "_xlnm.Print_Titles":
                printTitles[index] = value
            default:
                break
            }
        }

        let drawingColors = DrawingColors(theme: theme)
        let entries = workbook.sml("sheets")?.smlChildren("sheet") ?? []
        for (index, entry) in entries.enumerated() {
            guard let id = entry.attribute(forLocalName: "id", uri: OOXMLNamespace.r)?.stringValue,
                  let path = targets[id],
                  let root = try package.xml(at: path)
            else {
                continue
            }
            var sheet = Self.sheet(
                root,
                strings: strings,
                styles: styles,
                formats: formats
            )
            sheet.name = entry.attributeValue("name") ?? "Sheet\(sheets.count + 1)"
            sheet.isHidden = (entry.attributeValue("state") ?? "visible") != "visible"
            sheet.printArea = printAreas[index].flatMap(Self.area)
            sheet.titleRows = printTitles[index].flatMap(Self.titleRows)
            if let drawingID = root.sml("drawing")?.attribute(forLocalName: "id", uri: OOXMLNamespace.r)?.stringValue,
               let drawingPath = try package.relationships(of: path).first(where: { $0.id == drawingID })?.path,
               let drawing = try package.xml(at: drawingPath) {
                sheet.drawings = try XLSXDrawing.drawings(
                    in: drawing,
                    path: drawingPath,
                    package: package,
                    colors: drawingColors
                )
            }
            sheets.append(sheet)
        }

        // Charts can point at any sheet's cells, so they are read once all are.
        let lookup = self
        for sheetIndex in sheets.indices {
            sheets[sheetIndex].drawings = sheets[sheetIndex].drawings.compactMap { drawing in
                var drawing = drawing
                drawing.items = drawing.items.compactMap { item in
                    guard case .chartPart(let chartPath) = item.content else {
                        return item
                    }
                    guard let root = try? package.xml(at: chartPath),
                          let chart = XLSXChart(
                              root,
                              colors: drawingColors,
                              formats: formats,
                              cells: { lookup.cells(in: $0) }
                          )
                    else {
                        return nil
                    }
                    var item = item
                    item.content = .chart(chart)
                    return item
                }
                return drawing.items.isEmpty ? nil : drawing
            }
        }
        let active = workbook.sml("bookViews")?.sml("workbookView")?.attributeValue("activeTab").flatMap(Int.init) ?? 0
        if sheets.indices.contains(active), !sheets[active].isHidden {
            activeSheet = active
        } else {
            activeSheet = sheets.firstIndex { !$0.isHidden } ?? 0
        }
    }

    // MARK: Parts

    private static func sharedStrings(_ root: XMLElement?) -> [String] {
        (root?.smlChildren("si") ?? []).map(richText)
    }

    /// A string item's text: its own `t`, or its runs' `t`s, leaving out phonetic guides. Capped at Excel's cell limit.
    private static func richText(_ item: XMLElement) -> String {
        if let text = item.sml("t") {
            return XLSXWriter.fitted(text.stringValue ?? "")
        }
        return XLSXWriter.fitted(item.smlChildren("r")
            .map { $0.sml("t")?.stringValue ?? "" }
            .joined())
    }

    private static func styles(_ root: XMLElement?, colors: SpreadsheetColors) -> [Style] {
        guard let root else {
            return [Style()]
        }
        let fonts = (root.sml("fonts")?.smlChildren("font") ?? []).map { font in
            Font(
                name: font.sml("name")?.attributeValue("val") ?? "Calibri",
                size: font.sml("sz")?.attributeValue("val").flatMap(Double.init) ?? 11,
                bold: font.sml("b")?.isSpreadsheetOn ?? false,
                italic: font.sml("i")?.isSpreadsheetOn ?? false,
                underline: font.sml("u").map { ($0.attributeValue("val") ?? "single") != "none" } ?? false,
                strike: font.sml("strike")?.isSpreadsheetOn ?? false,
                color: colors.css(font.sml("color"))
            )
        }
        let fills = (root.sml("fills")?.smlChildren("fill") ?? []).map { fill -> String? in
            if let pattern = fill.sml("patternFill") {
                let type = pattern.attributeValue("patternType") ?? "none"
                guard type != "none", type != "gray125" else {
                    return nil
                }
                return colors.css(pattern.sml(type == "solid" ? "fgColor" : "bgColor") ?? pattern.sml("fgColor"))
            }
            return colors.css(fill.sml("gradientFill")?.sml("stop")?.sml("color"))
        }
        let borders = (root.sml("borders")?.smlChildren("border") ?? []).map { border in
            var sides: [String: String] = [:]
            for side in ["top", "left", "bottom", "right"] {
                guard let element = border.sml(side),
                      let style = element.attributeValue("style"),
                      let css = Self.borderCSS(style)
                else {
                    continue
                }
                sides[side] = "\(css) \(colors.css(element.sml("color")) ?? "#000")"
            }
            return sides
        }

        let formats = root.sml("cellXfs")?.smlChildren("xf") ?? []
        guard !formats.isEmpty else {
            return [Style(font: fonts.first ?? Font())]
        }
        return formats.map { xf in
            func index(_ name: String) -> Int {
                xf.attributeValue(name).flatMap(Int.init) ?? 0
            }
            let alignment = xf.sml("alignment")
            return Style(
                font: fonts.indices.contains(index("fontId")) ? fonts[index("fontId")] : fonts.first ?? Font(),
                fill: fills.indices.contains(index("fillId")) ? fills[index("fillId")] : nil,
                borders: borders.indices.contains(index("borderId")) ? borders[index("borderId")] : [:],
                horizontal: alignment?.attributeValue("horizontal"),
                vertical: alignment?.attributeValue("vertical"),
                wraps: alignment?.attributeValue("wrapText").map { $0 == "1" || $0 == "true" } ?? false,
                indent: alignment?.attributeValue("indent").flatMap(Int.init) ?? 0,
                numberFormat: index("numFmtId")
            )
        }
    }

    private static func borderCSS(_ style: String) -> String? {
        switch style {
        case "hair":
            "0.5pt solid"
        case "thin":
            "0.75pt solid"
        case "medium":
            "1.5pt solid"
        case "thick":
            "2.25pt solid"
        case "dashed", "mediumDashed":
            "0.75pt dashed"
        case "dotted":
            "0.75pt dotted"
        case "double":
            "2.25pt double"
        case "dashDot", "dashDotDot", "mediumDashDot", "mediumDashDotDot", "slantDashDot":
            "0.75pt dashed"
        default:
            nil
        }
    }

    private static func sheet(
        _ root: XMLElement,
        strings: [String],
        styles: [Style],
        formats: NumberFormats
    ) -> Sheet {
        var sheet = Sheet(name: "")
        if let format = root.sml("sheetFormatPr") {
            if let width = format.attributeValue("defaultColWidth").flatMap(Double.init) {
                sheet.defaultColumnWidth = width
            } else if let base = format.attributeValue("baseColWidth").flatMap(Double.init) {
                // Excel pads the base width by five pixels and rounds up to a multiple of eight.
                sheet.defaultColumnWidth = ((base * 7 + 5) / 8).rounded(.up) * 8 / 7
            }
            if let height = format.attributeValue("defaultRowHeight").flatMap(Double.init) {
                sheet.defaultRowHeight = height
            }
        }
        for column in root.sml("cols")?.smlChildren("col") ?? [] {
            guard let min = column.attributeValue("min").flatMap(Int.init),
                  let max = column.attributeValue("max").flatMap(Int.init),
                  min >= 1, min <= 1024, max >= min
            else {
                continue
            }
            // A last range often reaches column 16384 to style the rest of the sheet.
            for index in (min - 1)...Swift.min(max - 1, 1023) {
                if let width = column.attributeValue("width").flatMap(Double.init) {
                    sheet.columnWidths[index] = width
                }
                if column.attributeValue("hidden") == "1" || column.attributeValue("hidden") == "true" {
                    sheet.hiddenColumns.insert(index)
                }
            }
        }

        var nextRow = 0
        for row in root.sml("sheetData")?.smlChildren("row") ?? [] {
            let number = row.attributeValue("r").flatMap(Int.init)
            guard (1...XLSXWriter.maxRows).contains(number ?? 1) else {
                continue
            }
            let rowIndex = number.map { $0 - 1 } ?? nextRow
            nextRow = rowIndex + 1
            if let height = row.attributeValue("ht").flatMap(Double.init) {
                sheet.rowHeights[rowIndex] = height
            }
            if row.attributeValue("hidden") == "1" || row.attributeValue("hidden") == "true" {
                sheet.hiddenRows.insert(rowIndex)
            }
            var nextColumn = 0
            for cell in row.smlChildren("c") {
                let column = cell.attributeValue("r").flatMap { Self.position($0)?.column } ?? nextColumn
                nextColumn = column + 1
                guard rowIndex < XLSXWriter.maxRows, column < XLSXWriter.maxColumns else {
                    continue
                }
                let style = cell.attributeValue("s").flatMap(Int.init) ?? 0
                let format = styles.indices.contains(style) ? styles[style].numberFormat : 0
                guard let value = Self.value(
                    cell,
                    strings: strings,
                    format: format,
                    formats: formats
                ) else {
                    // An empty cell still shows its fill and borders.
                    if style != 0 {
                        sheet.cells[rowIndex, default: [:]][column] = Cell(
                            text: "",
                            kind: .text,
                            style: style
                        )
                    }
                    continue
                }
                sheet.cells[rowIndex, default: [:]][column] = Cell(
                    text: value.text,
                    kind: value.kind,
                    style: style,
                    number: value.number
                )
            }
        }

        for merge in root.sml("mergeCells")?.smlChildren("mergeCell") ?? [] {
            let corners = (merge.attributeValue("ref") ?? "").split(separator: ":")
            guard corners.count == 2,
                  let start = Self.position(String(corners[0])),
                  let end = Self.position(String(corners[1]))
            else {
                continue
            }
            sheet.merges.append(
                Sheet.Merge(
                    top: start.row,
                    left: start.column,
                    bottom: end.row,
                    right: end.column
                )
            )
        }

        if let margins = root.sml("pageMargins") {
            func inches(_ name: String, _ fallback: Double) -> Double {
                margins.attributeValue(name).flatMap(Double.init) ?? fallback
            }
            sheet.page.margins = (
                top: inches("top", 0.75),
                left: inches("left", 0.7),
                bottom: inches("bottom", 0.75),
                right: inches("right", 0.7)
            )
        }
        if let setup = root.sml("pageSetup") {
            sheet.page.landscape = setup.attributeValue("orientation").flatMap { orientation in
                orientation == "default" ? nil : orientation == "landscape"
            }
            sheet.page.paper = setup.attributeValue("paperSize").flatMap(Int.init) ?? 9
            sheet.page.scale = setup.attributeValue("scale").flatMap(Int.init) ?? 100
            sheet.page.pagesWide = setup.attributeValue("fitToWidth").flatMap(Int.init) ?? 1
            sheet.page.pagesTall = setup.attributeValue("fitToHeight").flatMap(Int.init) ?? 1
            sheet.page.acrossFirst = setup.attributeValue("pageOrder") == "overThenDown"
        }
        let fitsToPage = root.sml("sheetPr")?.sml("pageSetUpPr")?.attributeValue("fitToPage")
        sheet.page.fitsToPages = fitsToPage == "1" || fitsToPage == "true"
        for pageBreak in root.sml("rowBreaks")?.smlChildren("brk") ?? [] {
            // A break's id is the row it falls below, counted from 1: the next page starts there.
            if let row = pageBreak.attributeValue("id").flatMap(Int.init), row > 0 {
                sheet.pageBreaks.insert(row)
            }
        }
        let gridLines = root.sml("printOptions")?.attributeValue("gridLines")
        sheet.page.gridLines = gridLines == "1" || gridLines == "true"
        return sheet
    }

    private static func value(
        _ cell: XMLElement,
        strings: [String],
        format: Int,
        formats: NumberFormats
    ) -> (text: String, kind: Cell.Kind, number: Double?)? {
        let raw = cell.sml("v")?.stringValue
        switch cell.attributeValue("t") ?? "n" {
        case "s":
            guard let index = raw.flatMap(Int.init), strings.indices.contains(index) else {
                return nil
            }
            return (strings[index], .text, nil)
        case "inlineStr":
            return cell.sml("is").map { (richText($0), .text, nil) }
        case "str", "d":
            return raw.map { (XLSXWriter.fitted($0), .text, nil) }
        case "b":
            return raw.map { ($0 == "1" ? "TRUE" : "FALSE", .boolean, nil) }
        case "e":
            return raw.map { ($0, .error, nil) }
        default:
            guard let raw, let number = Double(raw) else {
                return raw.map { ($0, .text, nil) }
            }
            return (formats.text(for: number, format: format), .number, number)
        }
    }

    /// The cells a reference such as `'매출 1'!$B$2:$B$9` points at, row by row.
    func cells(in reference: String) -> [Cell?] {
        let parts = reference.split(separator: "!", maxSplits: 1)
        guard parts.count == 2 else {
            return []
        }
        var name = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "="))
        if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
            name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard let sheet = sheets.first(where: { $0.name == name }),
              let area = Self.area(String(parts[1]))
        else {
            return []
        }
        // A reference to whole columns would otherwise run a million rows.
        let lastRow = min(area.rows.upperBound, sheet.cells.keys.max() ?? area.rows.lowerBound)
        guard lastRow >= area.rows.lowerBound else {
            return []
        }
        var cells: [Cell?] = []
        for row in area.rows.lowerBound...lastRow {
            for column in area.columns {
                cells.append(sheet.cells[row]?[column])
            }
        }
        return cells
    }

    /// The first area of a reference such as `Sheet1!$A$1:$H$40,Sheet1!$J$1:$K$9`, or one cell.
    static func area(_ reference: String) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        for part in reference.split(separator: ",") {
            let local = part.split(separator: "!").last.map(String.init) ?? String(part)
            let corners = local.split(separator: ":").map(String.init)
            guard let start = corners.first.flatMap(position) else {
                continue
            }
            let end = corners.count > 1 ? position(corners[1]) ?? start : start
            return (
                min(start.row, end.row)...max(start.row, end.row),
                min(start.column, end.column)...max(start.column, end.column)
            )
        }
        return nil
    }

    /// The rows of a print titles name such as `Sheet1!$A:$B,Sheet1!$1:$2`.
    static func titleRows(_ reference: String) -> ClosedRange<Int>? {
        for part in reference.split(separator: ",") {
            let local = part.split(separator: "!").last.map(String.init) ?? String(part)
            let rows = local
                .split(separator: ":")
                .map { $0.filter { $0 != "$" } }
                .compactMap { Int($0) }
            if rows.count == 2, rows.allSatisfy({ (1...XLSXWriter.maxRows).contains($0) }) {
                return (min(rows[0], rows[1]) - 1)...(max(rows[0], rows[1]) - 1)
            }
        }
        return nil
    }

    /// "AB12" → row 11, column 27. Nil outside Excel's sheet limits.
    static func position(_ reference: String) -> (row: Int, column: Int)? {
        var column = 0
        var digits = ""
        for character in reference.uppercased() {
            if let ascii = character.asciiValue, (65...90).contains(ascii), digits.isEmpty {
                column = column * 26 + Int(ascii - 64)
                guard column <= XLSXWriter.maxColumns else {
                    return nil
                }
            } else if character.isNumber {
                digits.append(character)
            } else if character != "$" {
                return nil
            }
        }
        guard column > 0, let row = Int(digits), (1...XLSXWriter.maxRows).contains(row) else {
            return nil
        }
        return (row - 1, column - 1)
    }
}

/// The zip container and its relationships, for any OOXML package.
struct XLSXPackage {
    struct Relationship {
        var id: String
        var type: String
        var path: String
    }

    let archive: Archive

    func data(at path: String) throws -> Data? {
        try DocxPackage.data(in: archive, at: path)
    }

    func xml(at path: String) throws -> XMLElement? {
        guard let data = try data(at: path) else {
            return nil
        }
        return try PackageXML.root(data)
    }

    func relationships(of part: String) throws -> [Relationship] {
        guard let root = try xml(at: DocxPackage.relsPath(for: part)) else {
            return []
        }
        return root.elements.compactMap { element in
            guard element.attributeValue("TargetMode") != "External",
                  let id = element.attributeValue("Id"),
                  let type = element.attributeValue("Type"),
                  let target = element.attributeValue("Target")
            else {
                return nil
            }
            return Relationship(
                id: id,
                type: type,
                path: DocxPackage.resolve(target, relativeTo: part)
            )
        }
    }
}

extension XMLElement {
    func sml(_ name: String) -> XMLElement? {
        child(name, in: SpreadsheetNamespace.main)
    }

    func smlChildren(_ name: String) -> [XMLElement] {
        children(name, in: SpreadsheetNamespace.main)
    }

    /// An attribute without a namespace, as SpreadsheetML writes most of them.
    func attributeValue(_ name: String) -> String? {
        attribute(forName: name)?.stringValue
    }

    /// `<b/>` is on, `<b val="0"/>` is off.
    var isSpreadsheetOn: Bool {
        !["0", "false"].contains(attributeValue("val") ?? "1")
    }
}
