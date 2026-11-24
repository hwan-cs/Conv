import Foundation
import ZIPFoundation

/// Builds an `HwpDocument` from a .hwpx package (OWPML, KS X 6101): a ZIP of XML parts that
/// carry the same model as the binary records.
struct HwpxReader {
    enum ReaderError: Error {
        case notAnHwpx
    }

    private let archive: Archive
    private var manifest: [String: String] = [:]
    private var binIDs: [String: Int] = [:]

    init(url: URL) throws {
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ReaderError.notAnHwpx
        }
        guard archive["Contents/header.xml"] != nil else {
            throw ReaderError.notAnHwpx
        }
    }

    static func isPackage(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer {
            try? handle.close()
        }
        return (try? handle.read(upToCount: 2)) == Data("PK".utf8)
    }

    mutating func read() throws -> HwpDocument {
        var document = HwpDocument()
        var sections: [String] = []
        if let package = try xml("Contents/content.hpf") {
            for item in package.descendants(named: "item") {
                guard let id = item.string("id"), let href = item.string("href") else {
                    continue
                }
                if href.hasPrefix("BinData/") {
                    manifest[id] = href
                } else if id.hasPrefix("section") || href.contains("section") {
                    sections.append(href)
                }
            }

            let order = package.descendants(named: "itemref").compactMap { $0.string("idref") }
            if !order.isEmpty {
                let byID = Dictionary(package.descendants(named: "item").compactMap { item in
                    item.string("id").flatMap { id in item.string("href").map { (id, $0) } }
                }, uniquingKeysWith: { first, _ in first })
                let spine = order.compactMap { byID[$0] }.filter { $0.contains("section") }
                if !spine.isEmpty {
                    sections = spine
                }
            }
        }
        if sections.isEmpty {
            sections = (0..<100).map { "Contents/section\($0).xml" }.prefix { archive[$0] != nil }.map { $0 }
        }
        for (index, (id, path)) in manifest.sorted(by: { $0.key < $1.key }).enumerated() {
            binIDs[id] = index + 1
            let archive = archive
            let ext = (path as NSString).pathExtension.lowercased()
            document.binData[index + 1] = HwpDocument.BinItem(extension: ext) {
                try Self.data(in: archive, at: path)
            }
        }

        guard let header = try xml("Contents/header.xml") else {
            throw ReaderError.notAnHwpx
        }
        readHeader(header, into: &document)
        for path in sections {
            guard let root = try xml(path) else {
                continue
            }
            var section = HwpDocument.Section()
            section.paragraphs = root.elements.filter { $0.localName == "p" }.map { paragraph($0, section: &section) }
            document.sections.append(section)
        }
        return document
    }

    // MARK: Header
    private func readHeader(_ header: XMLElement, into document: inout HwpDocument) {
        let scripts = ["HANGUL", "LATIN", "HANJA", "JAPANESE", "OTHER", "SYMBOL", "USER"]
        for fontface in header.descendants(named: "fontface") {
            guard let script = scripts.firstIndex(of: fontface.string("lang") ?? "") else {
                continue
            }
            document.fonts[script] = fontface.children(named: "font").sorted { $0.int("id") < $1.int("id") }.map { font in
                HwpDocument.Font(name: font.string("face") ?? "", fallback: font.child(named: "substFont")?.string("face"))
            }
        }
        document.borderFills = header.descendants(named: "borderFill").sorted { $0.int("id") < $1.int("id") }.map(borderFill)
        document.charShapes = header.descendants(named: "charPr").sorted { $0.int("id") < $1.int("id") }.map(charShape)
        document.tabDefs = header.descendants(named: "tabPr").sorted { $0.int("id") < $1.int("id") }.map(tabDef)
        document.numberings = header.descendants(named: "numbering").sorted { $0.int("id") < $1.int("id") }.map { numbering in
            var levels = numbering.children(named: "paraHead").sorted { $0.int("level") < $1.int("level") }.map(level)
            while levels.count < 7 {
                levels.append(.init(format: "", style: 0, start: 1))
            }
            return HwpDocument.Numbering(levels: levels)
        }
        document.bullets = header.descendants(named: "bullet").sorted { $0.int("id") < $1.int("id") }.map { bullet in
            HwpDocument.Bullet(character: bullet.string("char") ?? "•", spacing: bullet.child(named: "paraHead").map(headSpacing) ?? .init())
        }
        document.paraShapes = header.descendants(named: "paraPr").sorted { $0.int("id") < $1.int("id") }.map(paraShape)
    }

    private func borderFill(_ element: XMLElement) -> HwpDocument.BorderFill {
        func side(_ name: String) -> HwpDocument.Border {
            guard let border = element.child(named: name) else {
                return .none
            }
            let width = Double((border.string("width") ?? "0.1").split(separator: " ").first ?? "0.1") ?? 0.1
            return HwpDocument.Border(
                style: Self.lineStyle(border.string("type")),
                width: width,
                color: Self.color(border.string("color")) ?? .black
            )
        }
        var fill = HwpDocument.BorderFill(
            left: side("leftBorder"),
            right: side("rightBorder"),
            top: side("topBorder"),
            bottom: side("bottomBorder")
        )
        fill.fill = element.descendant(named: "winBrush").flatMap { Self.color($0.string("faceColor")) }
        fill.image = imageFill(element.descendant(named: "imgBrush"))
        return fill
    }

    private func charShape(_ element: XMLElement) -> HwpDocument.CharShape {
        func perScript(_ name: String, default value: Int) -> [Int] {
            let keys = ["hangul", "latin", "hanja", "japanese", "other", "symbol", "user"]
            guard let item = element.child(named: name) else {
                return Array(repeating: value, count: 7)
            }
            return keys.map { item.string($0).flatMap(Int.init) ?? value }
        }
        let underline: HwpDocument.CharShape.Underline? = switch element.child(named: "underline")?.string("type") {
        case "BOTTOM": .below
        case "TOP": .above
        default: nil
        }
        let borderFillID = element.int("borderFillIDRef")
        return HwpDocument.CharShape(
            faces: perScript("fontRef", default: 0),
            ratios: perScript("ratio", default: 100),
            spacings: perScript("spacing", default: 0),
            relativeSizes: perScript("relSz", default: 100),
            offsets: perScript("offset", default: 0),
            height: element.int("height", default: 1000),
            italic: element.child(named: "italic") != nil,
            bold: element.child(named: "bold") != nil,
            underline: underline,
            strikeout: (element.child(named: "strikeout")?.string("shape") ?? "NONE") != "NONE",
            isSuperscript: element.child(named: "supscript") != nil,
            isSubscript: element.child(named: "subscript") != nil,
            color: Self.color(element.string("textColor")) ?? .black,
            shadeColor: Self.color(element.string("shadeColor")),
            borderFillID: borderFillID > 0 ? borderFillID : nil
        )
    }

    private func tabDef(_ element: XMLElement) -> HwpDocument.TabDef {
        var definition = HwpDocument.TabDef(
            hangingStop: element.string("autoTabLeft") == "1",
            rightEndStop: element.string("autoTabRight") == "1"
        )
        let settings = Self.preferringCase(element)
        definition.stops = settings.descendants(named: "tabItem").map { item in
            let kind: HwpDocument.TabStop.Kind = switch item.string("type") {
            case "RIGHT": .right
            case "CENTER": .center
            case "DECIMAL": .decimal
            default: .left
            }
            return HwpDocument.TabStop(
                position: Self.length(item, "pos", inCase: settings !== element),
                kind: kind,
                leader: (item.string("leader") ?? "NONE") != "NONE"
            )
        }
        return definition
    }

    private func level(_ head: XMLElement) -> HwpDocument.Numbering.Level {
        HwpDocument.Numbering.Level(
            format: head.stringValue ?? "",
            style: Self.numberStyle(head.string("numFormat")),
            start: head.int("start", default: 1),
            spacing: headSpacing(head)
        )
    }

    private func headSpacing(_ head: XMLElement) -> HwpDocument.HeadSpacing {
        let charShape = head.string("charPrIDRef").flatMap(Int.init)
        return HwpDocument.HeadSpacing(
            distance: head.int("textOffset", default: 50),
            distanceIsPercent: (head.string("textOffsetType") ?? "PERCENT") == "PERCENT",
            autoIndent: head.string("autoIndent") == "1",
            charShapeID: charShape == 4_294_967_295 ? nil : charShape
        )
    }

    private func paraShape(_ element: XMLElement) -> HwpDocument.ParaShape {
        var shape = HwpDocument.ParaShape()
        shape.alignment = switch element.child(named: "align")?.string("horizontal") {
        case "LEFT": .left
        case "RIGHT": .right
        case "CENTER": .center
        case "DISTRIBUTE": .distribute
        case "DISTRIBUTE_SPACE": .divide
        default: .justify
        }
        shape.tabDefID = element.int("tabPrIDRef")
        if let heading = element.child(named: "heading"), let kind = heading.string("type"), kind != "NONE" {
            shape.heading = .init(
                kind: kind == "OUTLINE" ? .outline : kind == "BULLET" ? .bullet : .numbering,
                id: heading.int("idRef"),
                level: heading.int("level")
            )
        }
        shape.pageBreakBefore = element.child(named: "breakSetting")?.string("pageBreakBefore") == "1"
        let settings = Self.preferringCase(element)
        if let margin = settings.descendant(named: "margin") {
            shape.indent = margin.child(named: "intent").map { Self.length($0, "value", inCase: settings !== element) } ?? 0
            shape.left = margin.child(named: "left").map { Self.length($0, "value", inCase: settings !== element) } ?? 0
            shape.right = margin.child(named: "right").map { Self.length($0, "value", inCase: settings !== element) } ?? 0
            shape.spaceBefore = margin.child(named: "prev").map { Self.length($0, "value", inCase: settings !== element) } ?? 0
            shape.spaceAfter = margin.child(named: "next").map { Self.length($0, "value", inCase: settings !== element) } ?? 0
        }
        if let spacing = settings.descendant(named: "lineSpacing") {
            let value = spacing.int("value", default: 160)
            shape.lineSpacing = switch spacing.string("type") {
            case "FIXED": .fixed(value)
            case "BETWEEN_LINES": .betweenLines(value)
            case "AT_LEAST": .atLeast(value)
            default: .percent(value)
            }
        }
        if let border = element.child(named: "border") {
            let id = border.int("borderFillIDRef")
            shape.borderFillID = id > 0 ? id : nil
        }
        return shape
    }

    // MARK: Body
    private func paragraphs(in list: XMLElement?) -> [HwpDocument.Paragraph] {
        var ignored = HwpDocument.Section()
        return (list?.elements ?? []).filter { $0.localName == "p" }.map { paragraph($0, section: &ignored) }
    }

    private func paragraph(_ element: XMLElement, section: inout HwpDocument.Section) -> HwpDocument.Paragraph {
        var paragraph = HwpDocument.Paragraph()
        paragraph.paraShapeID = element.int("paraPrIDRef")
        paragraph.styleID = element.int("styleIDRef")
        paragraph.pageBreak = element.string("pageBreak") == "1"
        paragraph.columnBreak = element.string("columnBreak") == "1"
        paragraph.lineSegments = element.child(named: "linesegarray")?.children(named: "lineseg").map { segment in
            HwpDocument.LineSegment(
                textStart: segment.int("textpos"),
                verticalPosition: segment.int("vertpos"),
                lineHeight: segment.int("vertsize"),
                textHeight: segment.int("textheight"),
                baseline: segment.int("baseline"),
                spacing: segment.int("spacing"),
                columnStart: segment.int("horzpos"),
                width: segment.int("horzsize"),
                flags: UInt32(truncatingIfNeeded: segment.int("flags"))
            )
        } ?? []
        let runs = element.children(named: "run")
        paragraph.charShapeID = runs.first?.int("charPrIDRef") ?? 0

        var builder = ContentBuilder(lineStarts: Set(paragraph.lineSegments.map(\.textStart).filter { $0 > 0 }))
        for run in runs {
            let shapeID = run.int("charPrIDRef")
            for child in run.elements {
                switch child.localName {
                case "t":
                    for node in child.children ?? [] {
                        if let element = node as? XMLElement {
                            switch element.localName {
                            case "tab":
                                builder.append(.tab(charShapeID: shapeID), width: 8)
                            case "lineBreak":
                                builder.append(.lineBreak, width: 1)
                            case "nbSpace":
                                builder.text("\u{00A0}", shapeID: shapeID)
                            case "fwSpace":
                                builder.text("\u{2007}", shapeID: shapeID)
                            case "hyphen":
                                builder.text("-", shapeID: shapeID)
                            default:
                                break
                            }
                        } else if let text = node.stringValue {
                            builder.text(text.replacingOccurrences(of: Self.blankTextMarker, with: ""), shapeID: shapeID)
                        }
                    }
                case "secPr":
                    readSectionProperties(child, into: &section)
                    builder.skip(8)
                case "ctrl":
                    for control in child.elements {
                        if let parsed = self.control(control, shapeID: shapeID, section: &section) {
                            builder.append(.control(parsed), width: 8)
                        } else {
                            builder.skip(8)
                        }
                    }
                default:
                    if let object = object(child) {
                        builder.append(.control(object), width: 8)
                    }
                }
            }
        }
        paragraph.content = builder.content
        return paragraph
    }

    private func readSectionProperties(_ element: XMLElement, into section: inout HwpDocument.Section) {
        // 기본 탭 간격, stored at twice its size like the binary's.
        section.defaultTab = element.int("tabStop", default: 8000) / 2
        section.columnGap = element.int("spaceColumns", default: 1134)
        section.outlineNumberingID = element.int("outlineShapeIDRef")
        section.pageNumberStart = element.child(named: "startNum")?.int("page") ?? 0
        if let notes = element.child(named: "endNotePr") {
            let format = notes.child(named: "autoNumFormat")
            let spacing = notes.child(named: "noteSpacing")
            section.endnoteShape = .init(
                prefix: format?.string("prefixChar") ?? "",
                suffix: format?.string("suffixChar") ?? ")",
                start: max(notes.child(named: "numbering")?.int("newNum") ?? 1, 1),
                spaceAbove: spacing?.int("aboveLine") ?? 850,
                spaceBelow: spacing?.int("belowLine") ?? 567,
                spaceBetween: spacing?.int("betweenNotes") ?? 0
            )
        }
        if let pagePr = element.child(named: "pagePr") {
            var page = HwpDocument.PageDef()
            page.width = pagePr.int("width", default: page.width)
            page.height = pagePr.int("height", default: page.height)
            if let margin = pagePr.child(named: "margin") {
                page.left = margin.int("left")
                page.right = margin.int("right")
                page.top = margin.int("top")
                page.bottom = margin.int("bottom")
                page.header = margin.int("header")
                page.footer = margin.int("footer")
                page.gutter = margin.int("gutter")
            }

            page.landscape = pagePr.string("landscape") == "NARROWLY"
            if page.landscape, page.width < page.height {
                swap(&page.width, &page.height)
            }
            section.page = page
        }
    }

    private func control(_ element: XMLElement, shapeID: Int, section: inout HwpDocument.Section) -> HwpDocument.Control? {
        switch element.localName {
        case "colPr":
            section.columns = max(element.int("colCount", default: 1), 1)
            if let gap = element.string("sameGap").flatMap(Int.init), gap > 0 {
                section.columnGap = gap
            }
            return nil
        case "header", "footer":
            let pages: HwpDocument.HeaderFooter.Pages = switch element.string("applyPageType") {
            case "EVEN": .even
            case "ODD": .odd
            default: .both
            }
            let content = HwpDocument.HeaderFooter(pages: pages, paragraphs: paragraphs(in: element.child(named: "subList")))
            return element.localName == "header" ? .header(content) : .footer(content)
        case "footNote":
            return .footnote(paragraphs(in: element.child(named: "subList")))
        case "endNote":
            return .endnote(paragraphs(in: element.child(named: "subList")))
        case "autoNum":
            let kinds: [String: HwpDocument.AutoNumber.Kind] = [
                "PAGE": .page, "FOOTNOTE": .footnote, "ENDNOTE": .endnote, "PICTURE": .picture,
                "TABLE": .table, "EQUATION": .equation, "TOTAL_PAGE": .totalPages,
            ]
            return .autoNumber(.init(
                kind: kinds[element.string("numType") ?? ""] ?? .page,
                style: Self.numberStyle(element.child(named: "autoNumFormat")?.string("type")),
                number: element.int("num"),
                charShapeID: shapeID
            ))
        case "pageNum":
            let positions = ["NONE", "TOP_LEFT", "TOP_CENTER", "TOP_RIGHT", "BOTTOM_LEFT", "BOTTOM_CENTER", "BOTTOM_RIGHT",
                             "OUTSIDE_TOP", "OUTSIDE_BOTTOM", "INSIDE_TOP", "INSIDE_BOTTOM"]
            return .pageNumberPosition(.init(
                position: positions.firstIndex(of: element.string("pos") ?? "") ?? 0,
                style: Self.numberStyle(element.string("formatType")),
                prefix: "",
                suffix: "",
                dash: element.string("sideChar") ?? ""
            ))
        case "pageHiddenInfo":
            return .pageHide(
                header: element.string("hideHeader") == "1",
                footer: element.string("hideFooter") == "1",
                pageNumber: element.string("hidePageNum") == "1"
            )
        case "fieldBegin":
            guard element.string("type") == "HYPERLINK" else {
                return nil
            }
            let command = element.descendants(named: "stringParam").first { $0.string("name") == "Command" }?.stringValue ?? ""
            return .hyperlink(command.split(separator: ";").first.map { $0.replacingOccurrences(of: "\\:", with: ":") } ?? "")
        case "fieldEnd":
            return .fieldEnd
        default:
            return nil
        }
    }

    /// Tables, pictures, drawings and equations: everything placed with 개체 공통 속성.
    private func object(_ element: XMLElement) -> HwpDocument.Control? {
        var layout = Self.objectLayout(element)
        layout.caption = caption(of: element)
        switch element.localName {
        case "tbl":
            var table = HwpDocument.Table()
            table.layout = layout
            table.rows = element.int("rowCnt")
            table.columns = element.int("colCnt")
            table.cellSpacing = element.int("cellSpacing")
            table.borderFillID = element.int("borderFillIDRef")
            table.repeatHeader = element.string("repeatHeader") == "1"
            if let padding = element.child(named: "inMargin") {
                table.padding = (padding.int("left"), padding.int("right"), padding.int("top"), padding.int("bottom"))
            }
            for row in element.children(named: "tr") {
                for cellElement in row.children(named: "tc") {
                    var cell = HwpDocument.Table.Cell()
                    cell.borderFillID = cellElement.int("borderFillIDRef")
                    let list = cellElement.child(named: "subList")
                    cell.verticalAlign = switch list?.string("vertAlign") {
                    case "CENTER":
                        1
                    case "BOTTOM":
                        2
                    default:
                        0
                    }
                    cell.paragraphs = paragraphs(in: list)
                    cell.column = cellElement.child(named: "cellAddr")?.int("colAddr") ?? 0
                    cell.row = cellElement.child(named: "cellAddr")?.int("rowAddr") ?? 0
                    cell.columnSpan = max(cellElement.child(named: "cellSpan")?.int("colSpan") ?? 1, 1)
                    cell.rowSpan = max(cellElement.child(named: "cellSpan")?.int("rowSpan") ?? 1, 1)
                    cell.width = cellElement.child(named: "cellSz")?.int("width") ?? 0
                    cell.height = cellElement.child(named: "cellSz")?.int("height") ?? 0
                    if let margin = cellElement.child(named: "cellMargin") {
                        cell.padding = (margin.int("left"), margin.int("right"), margin.int("top"), margin.int("bottom"))
                    }
                    table.cells.append(cell)
                }
            }
            return .table(table)
        case "pic":
            var picture = HwpDocument.Picture()
            picture.layout = layout
            picture.binID = element.descendant(named: "img").flatMap { $0.string("binaryItemIDRef") }.flatMap { binIDs[$0] } ?? 0
            picture.border = Self.line(element.child(named: "lineShape"))
            if let clip = element.child(named: "imgClip") {
                picture.crop = (clip.int("left"), clip.int("top"), clip.int("right"), clip.int("bottom"))
            }
            if let corner = element.child(named: "imgRect")?.child(named: "pt2") {
                picture.extent = (corner.int("x"), corner.int("y"))
            }
            picture.effect = HwpDocument.Picture.Effect(hwpx: element.descendant(named: "img")?.string("effect"))
            return .picture(picture)
        case "equation":
            return .equation(.init(
                layout: layout,
                script: element.child(named: "script")?.stringValue ?? "",
                fontSize: element.int("baseUnit", default: 1000),
                color: Self.color(element.string("textColor")) ?? .black
            ))
        case "rect", "ellipse", "line", "arc", "polygon", "curve", "container", "connectLine":
            return .shape(shape(element, layout: layout))
        default:
            return nil
        }
    }

    /// 그림 채우기: `<hc:imgBrush mode="…"><hc:img binaryItemIDRef="…"/>`.
    private func imageFill(_ brush: XMLElement?) -> HwpDocument.ImageFill? {
        guard let brush, let id = brush.descendant(named: "img")?.string("binaryItemIDRef"), let binID = binIDs[id] else {
            return nil
        }
        let mode: HwpDocument.ImageFill.Mode = switch brush.string("mode") {
        case "TILE", "TILE_HORZ_TOP", "TILE_HORZ_BOTTOM", "TILE_VERT_LEFT", "TILE_VERT_RIGHT": .tile
        case "TOTAL", "FIT_TO_SIZE": .stretch
        default: .center
        }
        return HwpDocument.ImageFill(binID: binID, mode: mode, effect: .init(hwpx: brush.descendant(named: "img")?.string("effect")))
    }

    private func shape(_ element: XMLElement, layout: HwpDocument.ObjectLayout) -> HwpDocument.Shape {
        var shape = HwpDocument.Shape(layout: layout)
        shape.line = Self.line(element.child(named: "lineShape"))
        shape.fill = element.child(named: "fillBrush")?.child(named: "winBrush").flatMap { Self.color($0.string("faceColor")) }
        shape.image = imageFill(element.child(named: "fillBrush")?.child(named: "imgBrush"))
        switch element.localName {
        case "rect":
            shape.kind = .rectangle
            shape.cornerRatio = element.int("ratio")
        case "ellipse":
            shape.kind = .ellipse
        case "line":
            shape.kind = .line
            let start = element.child(named: "startPt")
            let end = element.child(named: "endPt")
            shape.start = (start?.int("x") ?? 0, start?.int("y") ?? 0)
            shape.end = (end?.int("x") ?? 0, end?.int("y") ?? 0)
        case "container":
            shape.children = element.elements.compactMap { child -> HwpDocument.Control? in
                guard ["rect", "ellipse", "line", "pic", "container", "arc", "polygon", "curve"].contains(child.localName ?? "") else {
                    return nil
                }
                var layout = HwpDocument.ObjectLayout()
                layout.inline = false
                layout.x = child.child(named: "offset")?.int("x") ?? 0
                layout.y = child.child(named: "offset")?.int("y") ?? 0
                layout.width = child.child(named: "curSz")?.int("width") ?? 0
                layout.height = child.child(named: "curSz")?.int("height") ?? 0
                if child.localName == "pic" {
                    var picture = HwpDocument.Picture()
                    picture.layout = layout
                    picture.binID = child.descendant(named: "img").flatMap { $0.string("binaryItemIDRef") }.flatMap { binIDs[$0] } ?? 0
                    return .picture(picture)
                }
                return .shape(self.shape(child, layout: layout))
            }
        default:
            shape.kind = .other
        }
        if let text = element.child(named: "drawText") {
            shape.text = paragraphs(in: text.child(named: "subList"))
            shape.textVerticalAlign = switch text.child(named: "subList")?.string("vertAlign") {
            case "CENTER":
                1
            case "BOTTOM":
                2
            default:
                0
            }
            if let margin = text.child(named: "textMargin") {
                shape.textPadding = (margin.int("left"), margin.int("right"), margin.int("top"), margin.int("bottom"))
            }
        }
        return shape
    }

    private func caption(of element: XMLElement) -> HwpDocument.Caption? {
        guard let caption = element.child(named: "caption") else {
            return nil
        }
        let side: HwpDocument.Caption.Side = switch caption.string("side") {
        case "LEFT":
            .left
        case "RIGHT":
            .right
        case "TOP":
            .top
        default: .bottom
        }
        return HwpDocument.Caption(
            side: side,
            width: caption.int("width"),
            gap: caption.int("gap"),
            paragraphs: paragraphs(in: caption.child(named: "subList"))
        )
    }

    private static func objectLayout(_ element: XMLElement) -> HwpDocument.ObjectLayout {
        var layout = HwpDocument.ObjectLayout()
        if let size = element.child(named: "sz") {
            layout.width = size.int("width")
            layout.height = size.int("height")
        }
        if let position = element.child(named: "pos") {
            layout.inline = position.string("treatAsChar") == "1"
            layout.vertical = switch position.string("vertRelTo") {
            case "PAPER": .paper
            case "PAGE": .page
            default: .paragraph
            }
            layout.horizontal = switch position.string("horzRelTo") {
            case "PAPER": .paper
            case "PAGE": .page
            case "PARA": .paragraph
            default: .column
            }
            let alignments = ["TOP": 0, "LEFT": 0, "CENTER": 1, "BOTTOM": 2, "RIGHT": 2, "INSIDE": 3, "OUTSIDE": 4]
            layout.verticalAlign = alignments[position.string("vertAlign") ?? ""] ?? 0
            layout.horizontalAlign = alignments[position.string("horzAlign") ?? ""] ?? 0
            layout.y = position.int("vertOffset")
            layout.x = position.int("horzOffset")
        }
        layout.wrap = switch element.string("textWrap") {
        case "SQUARE": .square
        case "TIGHT": .tight
        case "THROUGH": .through
        case "BEHIND_TEXT": .behindText
        case "IN_FRONT_OF_TEXT": .inFrontOfText
        default: .topAndBottom
        }
        layout.zOrder = element.int("zOrder")
        if let margin = element.child(named: "outMargin") {
            layout.margins = (margin.int("left"), margin.int("right"), margin.int("top"), margin.int("bottom"))
        }
        return layout
    }

    // MARK: Values

    private static func line(_ element: XMLElement?) -> HwpDocument.Border {
        guard let element, let style = lineStyle(element.string("style")) else {
            return .none
        }
        let width = element.int("width")
        guard width > 0 else {
            return .none
        }
        return .init(style: style, width: Double(width) / 283.465, color: color(element.string("color")) ?? .black)
    }

    static func lineStyle(_ name: String?) -> HwpDocument.Border.Style? {
        switch name {
        case "SOLID", "THICK_3D", "THICK_3D_REVERS", "3D", "3D_REVERS": .solid
        case "DASH": .dash
        case "DOT": .dot
        case "DASH_DOT": .dashDot
        case "DASH_DOT_DOT": .dashDotDot
        case "LONG_DASH": .longDash
        case "CIRCLE": .circle
        case "DOUBLE_SLIM": .double
        case "SLIM_THICK": .thinThick
        case "THICK_SLIM": .thickThin
        case "SLIM_THICK_SLIM": .triple
        case "WAVE", "DOUBLE_WAVE": .wave
        default: nil
        }
    }

    /// "#RRGGBB"; "none" and absent colors are nil.
    static func color(_ value: String?) -> HwpDocument.Color? {
        guard let value, value.hasPrefix("#"), value.count == 7, let number = UInt32(value.dropFirst(), radix: 16) else {
            return nil
        }
        return .init(red: UInt8(number >> 16 & 0xFF), green: UInt8(number >> 8 & 0xFF), blue: UInt8(number & 0xFF))
    }

    /// 번호 모양 names, as the binary format's codes.
    static func numberStyle(_ name: String?) -> Int {
        let names = ["DIGIT", "CIRCLED_DIGIT", "ROMAN_CAPITAL", "ROMAN_SMALL", "LATIN_CAPITAL", "LATIN_SMALL",
                     "CIRCLED_LATIN_CAPITAL", "CIRCLED_LATIN_SMALL", "HANGUL_SYLLABLE", "CIRCLED_HANGUL_SYLLABLE",
                     "HANGUL_JAMO", "CIRCLED_HANGUL_JAMO", "HANGUL_PHONETIC", "IDEOGRAPH", "CIRCLED_IDEOGRAPH"]
        return names.firstIndex(of: name ?? "") ?? 0
    }

    /// Newer Hangul writes true HWPUNIT values in an `hp:switch` case and twice-sized values for
    /// older readers in its default; elements without a switch carry the twice-sized values.
    private static func preferringCase(_ element: XMLElement) -> XMLElement {
        element.descendant(named: "switch")?.child(named: "case") ?? element
    }

    private static func length(_ element: XMLElement, _ name: String, inCase: Bool = false) -> Int {
        let value = element.int(name)
        return inCase ? value : value / 2
    }

    // MARK: Package
    static let blankTextMarker = "\u{E000}"

    private func xml(_ path: String) throws -> XMLElement? {
        guard let data = try Self.data(in: archive, at: path) else {
            return nil
        }
        return try PackageXML.root(Self.protectingBlankText(data))
    }

    /// libxml2 drops whitespace-only text nodes whatever the options, and Hangul writes the spaces
    /// between runs as exactly that; they are marked so they survive, and the marker is stripped on read.
    static func protectingBlankText(_ data: Data) -> Data {
        // Spaces right after <hp:t> or an empty element such as <hp:tab/>, up to the next tag.
        guard let blankText = try? Regex(#"(<hp:t(?: [^>]*)?>|<hp:[a-zA-Z]+/>)([ \t\x{3000}]+)(<)"#) else {
            return data
        }
        let xml = String(decoding: data, as: UTF8.self)
        guard xml.contains(blankText) else {
            return data
        }
        return Data(xml.replacing(blankText) { match in
            let whole = String(xml[match.range])
            let tagEnd = whole.firstIndex(of: ">").map { whole.index(after: $0) } ?? whole.startIndex
            return String(whole[..<tagEnd]) + blankTextMarker + String(whole[tagEnd...])
        }.utf8)
    }

    private static func data(in archive: Archive, at path: String) throws -> Data? {
        guard let entry = archive[path] else {
            return nil
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }
}

/// Collects a paragraph's content while counting text positions, starting lines where the saved layout does.
private struct ContentBuilder {
    let lineStarts: Set<Int>
    private(set) var content: [HwpDocument.Inline] = []
    private var position = 0

    init(lineStarts: Set<Int>) {
        self.lineStarts = lineStarts
    }

    mutating func text(_ text: String, shapeID: Int) {
        var pending = ""
        for unit in text.unicodeScalars {
            if lineStarts.contains(position), position > 0 {
                flush(&pending, shapeID: shapeID)
                content.append(.lineStart)
            }
            pending.unicodeScalars.append(unit)
            position += unit.utf16.count
        }
        flush(&pending, shapeID: shapeID)
    }

    mutating func append(_ item: HwpDocument.Inline, width: Int) {
        if lineStarts.contains(position), position > 0 {
            content.append(.lineStart)
        }
        content.append(item)
        position += width
    }

    mutating func skip(_ width: Int) {
        position += width
    }

    private mutating func flush(_ pending: inout String, shapeID: Int) {
        guard !pending.isEmpty else {
            return
        }
        if case .text(let previous, let previousShape) = content.last, previousShape == shapeID {
            content[content.count - 1] = .text(previous + pending, charShapeID: shapeID)
        } else {
            content.append(.text(pending, charShapeID: shapeID))
        }
        pending = ""
    }
}

private extension XMLElement {
    func children(named name: String) -> [XMLElement] {
        elements.filter { $0.localName == name }
    }

    func child(named name: String) -> XMLElement? {
        elements.first { $0.localName == name }
    }

    func descendant(named name: String) -> XMLElement? {
        for element in elements {
            if element.localName == name {
                return element
            }
            if let found = element.descendant(named: name) {
                return found
            }
        }
        return nil
    }

    func descendants(named name: String) -> [XMLElement] {
        elements.flatMap { ($0.localName == name ? [$0] : []) + $0.descendants(named: name) }
    }

    func string(_ name: String) -> String? {
        attribute(forName: name)?.stringValue
    }

    func int(_ name: String, default value: Int = 0) -> Int {
        string(name).flatMap { Int($0) ?? Double($0).map { Int($0) } } ?? value
    }
}
