import CoreGraphics
import Foundation

/// Builds an `HwpDocument` from the records of a .hwp 5.x file.
struct HwpBinaryReader {
    private let file: HwpFile

    init(file: HwpFile) {
        self.file = file
    }

    func read() throws -> HwpDocument {
        var document = HwpDocument()
        try readDocInfo(into: &document)
        for index in 0..<file.sectionCount {
            let tree = RecordNode.tree(try file.section(index))
            document.sections.append(readSection(tree))
        }
        return document
    }

    // MARK: DocInfo
    private func readDocInfo(into document: inout HwpDocument) throws {
        let records = try file.docInfo()
        var fontCounts: [Int] = []
        var fontIndex = 0
        var binCount = 0
        for record in records {
            var reader = ByteReader(record.payload)
            switch record.tag {
            case HwpTag.idMappings:
                _ = reader.int32()
                fontCounts = (0..<7).map { _ in Int(reader.int32()) }
            case HwpTag.binData:
                binCount += 1
                if let item = binItem(record.payload) {
                    document.binData[binCount] = item
                }
            case HwpTag.faceName:
                let flags = reader.uint8()
                let name = reader.string()
                var fallback: String?
                if flags & 0x80 != 0 {
                    _ = reader.uint8()
                    fallback = reader.string()
                }
                if flags & 0x40 != 0 {
                    reader.skip(10)
                }
                if flags & 0x20 != 0 {
                    fallback = reader.string()
                }
                // Faces arrive grouped by script, in the counts ID_MAPPINGS announced.
                var script = 0
                var remaining = fontIndex
                while script < fontCounts.count, remaining >= fontCounts[script] {
                    remaining -= fontCounts[script]
                    script += 1
                }
                if script < 7 {
                    document.fonts[script].append(.init(name: name, fallback: fallback))
                }
                fontIndex += 1
            case HwpTag.borderFill:
                document.borderFills.append(borderFill(&reader))
            case HwpTag.charShape:
                document.charShapes.append(charShape(&reader))
            case HwpTag.tabDef:
                document.tabDefs.append(tabDef(&reader))
            case HwpTag.numbering:
                document.numberings.append(numbering(&reader))
            case HwpTag.bullet:
                let spacing = headSpacing(&reader)
                let character = reader.uint16()
                document.bullets.append(.init(character: String(utf16CodeUnits: [character], count: 1), spacing: spacing))
            case HwpTag.paraShape:
                document.paraShapes.append(paraShape(&reader))
            default:
                break
            }
        }
    }

    private func binItem(_ payload: Data) -> HwpDocument.BinItem? {
        var reader = ByteReader(payload)
        let flags = reader.uint16()
        guard flags & 0xF != 0 else {
            return nil
        }
        let id = Int(reader.uint16())
        let ext = flags & 0xF == 1 ? reader.string() : "ole"
        let name = String(format: "BIN%04X.%@", id, ext)
        let file = file
        return HwpDocument.BinItem(extension: ext.lowercased()) { try file.binData(named: name) }
    }

    private func borderFill(_ reader: inout ByteReader) -> HwpDocument.BorderFill {
        _ = reader.uint16()
        var sides: [HwpDocument.Border] = []
        for _ in 0..<4 {
            let type = Int(reader.uint8())
            let width = Int(reader.uint8())
            let color = reader.uint32()
            sides.append(HwpDocument.Border(
                style: HwpDocument.Border.Style(code: type),
                width: HwpDocument.Border.widths[min(width, HwpDocument.Border.widths.count - 1)],
                color: HwpDocument.Color(colorRef: color) ?? .black
            ))
        }
        reader.skip(6) // Diagonal.
        let fill = Self.fill(&reader)
        return HwpDocument.BorderFill(
            left: sides[0],
            right: sides[1],
            top: sides[2],
            bottom: sides[3],
            fill: fill.color,
            image: fill.image
        )
    }

    /// 채우기 정보: a color, a gradation, a picture, each present by its bit in the type.
    static func fill(_ reader: inout ByteReader) -> (color: HwpDocument.Color?, image: HwpDocument.ImageFill?) {
        guard reader.remaining >= 4 else {
            return (nil, nil)
        }
        let type = reader.uint32()
        var color: HwpDocument.Color?
        if type & 1 != 0 {
            // Hatch patterns are drawn as their background color.
            color = HwpDocument.Color(colorRef: reader.uint32())
            reader.skip(8)
        }
        if type & 4 != 0 {
            // A gradation is drawn as its first color.
            reader.skip(10)
            let count = Int(reader.int16())
            guard count > 0, count < 1000 else {
                return (color, nil)
            }
            if count > 2 {
                reader.skip(count * 4)
            }
            let first = reader.uint32()
            reader.skip((count - 1) * 4)
            if color == nil {
                color = HwpDocument.Color(colorRef: first)
            }
        }
        var image: HwpDocument.ImageFill?
        if type & 2 != 0, reader.remaining >= 6 {
            let code = Int(reader.uint8())
            reader.skip(2)
            let effect = HwpDocument.Picture.Effect(code: Int(reader.uint8()))
            let binID = Int(reader.uint16())
            if binID > 0 {
                image = HwpDocument.ImageFill(binID: binID, code: code, effect: effect)
            }
        }
        return (color, image)
    }

    private func charShape(_ reader: inout ByteReader) -> HwpDocument.CharShape {
        let faces = (0..<7).map { _ in Int(reader.uint16()) }
        let ratios = (0..<7).map { _ in Int(reader.uint8()) }
        let spacings = (0..<7).map { _ in Int(reader.int8()) }
        let sizes = (0..<7).map { _ in Int(reader.uint8()) }
        let offsets = (0..<7).map { _ in Int(reader.int8()) }
        let height = Int(reader.int32())
        let flags = reader.uint32()
        reader.skip(2)
        let color = reader.uint32()
        _ = reader.uint32()
        let shade = reader.uint32()
        _ = reader.uint32()
        let borderFillID = reader.remaining >= 2 ? Int(reader.uint16()) : 0
        let underline: HwpDocument.CharShape.Underline? = switch flags >> 2 & 3 {
        case 1: .below
        case 3: .above
        default: nil
        }
        return HwpDocument.CharShape(
            faces: faces,
            ratios: ratios,
            spacings: spacings,
            relativeSizes: sizes,
            offsets: offsets,
            height: height,
            italic: flags & 1 != 0,
            bold: flags & 2 != 0,
            underline: underline,
            strikeout: flags >> 18 & 7 != 0,
            isSuperscript: flags & 1 << 15 != 0,
            isSubscript: flags & 1 << 16 != 0,
            color: HwpDocument.Color(colorRef: color) ?? .black,
            shadeColor: HwpDocument.Color(colorRef: shade),
            borderFillID: borderFillID > 0 ? borderFillID : nil
        )
    }

    private func paraShape(_ reader: inout ByteReader) -> HwpDocument.ParaShape {
        var shape = HwpDocument.ParaShape()
        let flags = reader.uint32()
        shape.alignment = .init(code: Int(flags >> 2 & 7))
        shape.pageBreakBefore = flags & 1 << 19 != 0
        // Margins, indent and spacing are stored at twice their HWPUNIT size
        shape.left = Int(reader.int32()) / 2
        shape.right = Int(reader.int32()) / 2
        shape.indent = Int(reader.int32()) / 2
        shape.spaceBefore = Int(reader.int32()) / 2
        shape.spaceAfter = Int(reader.int32()) / 2
        let oldSpacing = Int(reader.int32())
        shape.tabDefID = Int(reader.uint16())
        let headingID = Int(reader.uint16())
        let borderFillID = Int(reader.uint16())
        shape.borderFillID = borderFillID > 0 ? borderFillID : nil
        shape.borderOffsets = (Int(reader.int16()), Int(reader.int16()), Int(reader.int16()), Int(reader.int16()))
        let headingKind = flags >> 23 & 3
        if headingKind != 0 {
            shape.heading = .init(
                kind: headingKind == 1 ? .outline : headingKind == 2 ? .numbering : .bullet,
                id: headingID,
                level: Int(flags >> 25 & 7)
            )
        }
        var spacingType = Int(flags & 3)
        var spacing = oldSpacing
        if reader.remaining >= 12 {
            _ = reader.uint32()
            spacingType = Int(reader.uint32() & 0x1F)
            spacing = Int(reader.uint32())
        }
        shape.lineSpacing = switch spacingType {
        case 1: .fixed(spacing)
        case 2: .betweenLines(spacing)
        case 3: .atLeast(spacing)
        default: .percent(spacing)
        }
        return shape
    }

    private func tabDef(_ reader: inout ByteReader) -> HwpDocument.TabDef {
        let flags = reader.uint32()
        let count = Int(reader.int32())
        var tabDef = HwpDocument.TabDef(hangingStop: flags & 1 != 0, rightEndStop: flags & 2 != 0)
        tabDef.stops = (0..<max(count, 0)).compactMap { _ in
            guard reader.remaining >= 8 else {
                return nil
            }
            
            let position = Int(reader.int32()) / 2
            let kind = reader.uint8()
            let leader = reader.uint8()
            reader.skip(2)
            return HwpDocument.TabStop(
                position: position,
                kind: [.left, .right, .center, .decimal][min(Int(kind), 3)],
                leader: leader != 0
            )
        }
        return tabDef
    }

    /// 문단 머리 정보: flags, width adjustment, distance from the text, char shape.
    private func headSpacing(_ reader: inout ByteReader) -> HwpDocument.HeadSpacing {
        let flags = reader.uint32()
        _ = reader.uint16()
        let distance = Int(reader.uint16())
        let charShape = reader.uint32()
        return .init(
            distance: distance,
            distanceIsPercent: flags & 0x10 == 0,
            autoIndent: flags & 8 != 0,
            charShapeID: charShape == 0xFFFF_FFFF ? nil : Int(charShape)
        )
    }

    private func numbering(_ reader: inout ByteReader) -> HwpDocument.Numbering {
        var levels: [HwpDocument.Numbering.Level] = []
        for _ in 0..<7 {
            let style = Int(reader.uint32() >> 5 & 0xF)
            reader.skip(-4)
            let spacing = headSpacing(&reader)
            levels.append(.init(format: reader.string(), style: style, start: 1, spacing: spacing))
        }
        // Files before 5.0.2.5 have no per-level starts; Hangul counts from 1 when the start is 0.
        let start = max(Int(reader.uint16()), 1)
        for index in levels.indices {
            levels[index].start = reader.remaining >= 4 ? max(Int(reader.uint32()), 1) : start
        }
        return HwpDocument.Numbering(levels: levels)
    }

    // MARK: Body
    private func readSection(_ nodes: [RecordNode]) -> HwpDocument.Section {
        var section = HwpDocument.Section()
        section.paragraphs = paragraphs(in: nodes[...], section: &section)
        return section
    }

    private func paragraphs(in nodes: ArraySlice<RecordNode>, section: inout HwpDocument.Section) -> [HwpDocument.Paragraph] {
        nodes.filter { $0.record.tag == HwpTag.paraHeader }.map { paragraph($0, section: &section) }
    }

    private func paragraphs(in nodes: ArraySlice<RecordNode>) -> [HwpDocument.Paragraph] {
        var ignored = HwpDocument.Section()
        return paragraphs(in: nodes, section: &ignored)
    }

    private func paragraph(_ node: RecordNode, section: inout HwpDocument.Section) -> HwpDocument.Paragraph {
        var reader = ByteReader(node.record.payload)
        var paragraph = HwpDocument.Paragraph()
        _ = reader.uint32()
        _ = reader.uint32()
        paragraph.paraShapeID = Int(reader.uint16())
        paragraph.styleID = Int(reader.uint8())
        let breaks = reader.uint8()
        paragraph.pageBreak = breaks & 0x4 != 0
        paragraph.columnBreak = breaks & 0x8 != 0

        var text = Data()
        var runs: [(position: Int, id: Int)] = []
        var controls: [RecordNode] = []
        for child in node.children {
            switch child.record.tag {
            case HwpTag.paraText:
                text = child.record.payload
            case HwpTag.paraCharShape:
                var reader = ByteReader(child.record.payload)
                while reader.remaining >= 8 {
                    runs.append((Int(reader.uint32()), Int(reader.uint32())))
                }
            case HwpTag.paraLineSeg:
                var reader = ByteReader(child.record.payload)
                while reader.remaining >= 36 {
                    paragraph.lineSegments.append(.init(
                        textStart: Int(reader.int32()),
                        verticalPosition: Int(reader.int32()),
                        lineHeight: Int(reader.int32()),
                        textHeight: Int(reader.int32()),
                        baseline: Int(reader.int32()),
                        spacing: Int(reader.int32()),
                        columnStart: Int(reader.int32()),
                        width: Int(reader.int32()),
                        flags: reader.uint32()
                    ))
                }
            case HwpTag.ctrlHeader:
                controls.append(child)
            default:
                break
            }
        }

        paragraph.charShapeID = runs.first?.id ?? 0
        func charShape(at position: Int) -> Int {
            runs.last { $0.position <= position }?.id ?? runs.first?.id ?? 0
        }

        var pendingText = ""
        var pendingShape = charShape(at: 0)
        func flush() {
            if !pendingText.isEmpty {
                paragraph.content.append(.text(pendingText, charShapeID: pendingShape))
            }
            pendingText = ""
        }
        func append(_ string: String, at position: Int) {
            let shape = charShape(at: position)
            if shape != pendingShape {
                flush()
            }
            pendingShape = shape
            pendingText += string
        }

        var controlIterator = controls.makeIterator()
        let lineStarts = Set(paragraph.lineSegments.map(\.textStart).filter { $0 > 0 })
        var position = 0
        var units: [UInt16] = []
        while position * 2 + 1 < text.count {
            if lineStarts.contains(position) {
                flush()
                paragraph.content.append(.lineStart)
            }
            let code = text.uint16(at: position * 2)
            switch code {
            case 13:
                position = .max / 4
            case 10:
                flush()
                paragraph.content.append(.lineBreak)
                position += 1
            case 9:
                flush()
                paragraph.content.append(.tab(charShapeID: charShape(at: position)))
                position += 8
            case 24:
                append("-", at: position); position += 1
            case 30:
                append("\u{00A0}", at: position); position += 1
            case 31:
                append("\u{2007}", at: position); position += 1
            case 0, 25...29:
                position += 1
            case 4:
                flush()
                paragraph.content.append(.control(.fieldEnd))
                position += 8
            case 5...8, 19, 20:
                position += 8
            case 1...3, 11, 12, 14...18, 21...23:
                flush()
                if let control = controlIterator.next(),
                   let parsed = self.control(control, charShapeID: charShape(at: position), section: &section) {
                    paragraph.content.append(.control(parsed))
                }
                position += 8
            default:
                units.removeAll(keepingCapacity: true)
                var end = position
                while end * 2 + 1 < text.count, text.uint16(at: end * 2) >= 32, charShape(at: end) == charShape(at: position),
                      end == position || !lineStarts.contains(end) {
                    units.append(text.uint16(at: end * 2))
                    end += 1
                }
                append(String(decoding: units, as: UTF16.self), at: position)
                position = end
            }
        }
        flush()
        return paragraph
    }

    private func control(
        _ node: RecordNode,
        charShapeID: Int,
        section: inout HwpDocument.Section
    ) -> HwpDocument.Control? {
        let payload = node.record.payload
        switch Self.controlID(payload) {
        case "secd":
            section.defaultTab = Int(payload.uint32(at: 14)) / 2
            section.outlineNumberingID = Int(payload.uint16(at: 18))
            section.pageNumberStart = Int(payload.uint16(at: 20))
            // The section's two note shapes: footnotes, then endnotes.
            let noteShapes = node.children.filter { $0.record.tag == HwpTag.footnoteShape }
            if noteShapes.count > 1 {
                let data = noteShapes[1].record.payload
                func character(_ offset: Int) -> String {
                    let unit = data.uint16(at: offset)
                    return unit == 0 ? "" : String(utf16CodeUnits: [unit], count: 1)
                }
                section.endnoteShape = .init(
                    prefix: character(6),
                    suffix: character(8),
                    start: max(Int(data.uint16(at: 10)), 1),
                    spaceAbove: Int(data.uint16(at: 16)),
                    spaceBelow: Int(data.uint16(at: 18)),
                    spaceBetween: Int(data.uint16(at: 20))
                )
            }
            if let pageDef = node.children.first(where: { $0.record.tag == HwpTag.pageDef }) {
                var reader = ByteReader(pageDef.record.payload)
                var page = HwpDocument.PageDef()
                page.width = Int(reader.uint32())
                page.height = Int(reader.uint32())
                page.left = Int(reader.uint32())
                page.right = Int(reader.uint32())
                page.top = Int(reader.uint32())
                page.bottom = Int(reader.uint32())
                page.header = Int(reader.uint32())
                page.footer = Int(reader.uint32())
                page.gutter = Int(reader.uint32())
                page.landscape = reader.uint32() & 1 != 0
                if page.landscape, page.width < page.height {
                    swap(&page.width, &page.height)
                }
                section.page = page
            }
            return nil
        case "cold":
            let flags = payload.uint16(at: 4)
            section.columns = max(Int(flags >> 2 & 0xFF), 1)
            section.columnGap = Int(payload.uint16(at: 6))
            return nil
        case "tbl ":
            return table(node).map { .table($0) }
        case "gso ":
            var layout = Self.objectLayout(payload)
            layout.caption = caption(in: node.children, before: HwpTag.shapeComponent)
            return shapeObject(node, layout: layout)
        case "eqed":
            guard let record = node.children.first(where: { $0.record.tag == HwpTag.eqEdit }) else {
                return nil
            }
            var reader = ByteReader(record.record.payload)
            _ = reader.uint32()
            let script = reader.string()
            let size = Int(reader.uint32())
            let color = reader.uint32()
            var layout = Self.objectLayout(payload)
            layout.caption = caption(in: node.children, before: HwpTag.eqEdit)
            return .equation(.init(
                layout: layout,
                script: script,
                fontSize: size,
                color: HwpDocument.Color(colorRef: color) ?? .black
            ))
        case "head", "foot":
            let pages: HwpDocument.HeaderFooter.Pages = switch payload.uint32(at: 4) & 3 {
            case 1: .even
            case 2: .odd
            default: .both
            }
            let content = HwpDocument.HeaderFooter(pages: pages, paragraphs: paragraphs(in: node.children[...]))
            return Self.controlID(payload) == "head" ? .header(content) : .footer(content)
        case "fn  ":
            return .footnote(paragraphs(in: node.children[...]))
        case "en  ":
            return .endnote(paragraphs(in: node.children[...]))
        case "atno":
            let flags = payload.uint32(at: 4)
            let kinds: [HwpDocument.AutoNumber.Kind] = [.page, .footnote, .endnote, .picture, .table, .equation, .totalPages]
            return .autoNumber(.init(
                kind: kinds[min(Int(flags & 0xF), kinds.count - 1)],
                style: Int(flags >> 4 & 0xFF),
                number: Int(payload.uint16(at: 8)),
                charShapeID: charShapeID
            ))
        case "pghd":
            let flags = payload.uint32(at: 4)
            return .pageHide(header: flags & 1 != 0, footer: flags & 2 != 0, pageNumber: flags & 0x20 != 0)
        case "pgnp":
            let flags = payload.uint32(at: 4)
            func character(_ offset: Int) -> String {
                let unit = payload.uint16(at: offset)
                return unit == 0 ? "" : String(utf16CodeUnits: [unit], count: 1)
            }
            return .pageNumberPosition(.init(
                position: Int(flags >> 8 & 0xF),
                style: Int(flags & 0xFF),
                prefix: character(10),
                suffix: character(12),
                dash: character(14)
            ))
        case "%hlk":
            var reader = ByteReader(payload)
            reader.skip(9)
            let command = reader.string()
            let target = command.split(separator: ";", omittingEmptySubsequences: false).first
                .map { $0.replacingOccurrences(of: "\\:", with: ":") } ?? ""
            return .hyperlink(target)
        default:
            return nil
        }
    }

    static func controlID(_ payload: Data) -> String {
        let value = payload.uint32(at: 0)
        let bytes = [24, 16, 8, 0].map { UInt8(value >> $0 & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A shape component's 2×3 matrix: x' = a·x + b·y + c, y' = d·x + e·y + f.
    static func matrix(_ payload: Data, at offset: Int) -> CGAffineTransform {
        guard offset + 48 <= payload.count else {
            return .identity
        }
        let value = { payload.double(at: offset + $0 * 8) }
        return CGAffineTransform(a: value(0), b: value(3), c: value(1), d: value(4), tx: value(2), ty: value(5))
    }

    /// 개체 공통 속성, at the start of a table's, drawing's or equation's CTRL_HEADER.
    static func objectLayout(_ payload: Data) -> HwpDocument.ObjectLayout {
        var reader = ByteReader(payload)
        reader.skip(4)
        let flags = reader.uint32()
        var layout = HwpDocument.ObjectLayout()
        layout.inline = flags & 1 != 0
        layout.vertical = [.paper, .page, .paragraph, .paragraph][Int(flags >> 3 & 3)]
        layout.verticalAlign = Int(flags >> 5 & 7)
        layout.horizontal = [.paper, .page, .column, .paragraph][Int(flags >> 8 & 3)]
        layout.horizontalAlign = Int(flags >> 10 & 7)
        let wraps: [HwpDocument.ObjectLayout.Wrap] = [.square, .tight, .through, .topAndBottom, .behindText, .inFrontOfText]
        layout.wrap = wraps[min(Int(flags >> 21 & 7), wraps.count - 1)]
        layout.y = Int(reader.int32())
        layout.x = Int(reader.int32())
        layout.width = Int(reader.uint32())
        layout.height = Int(reader.uint32())
        layout.zOrder = Int(reader.int32())
        layout.margins = (Int(reader.int16()), Int(reader.int16()), Int(reader.int16()), Int(reader.int16()))
        return layout
    }

    /// A caption's list comes before the object's own record.
    private func caption(in children: [RecordNode], before tag: Int) -> HwpDocument.Caption? {
        let end = children.firstIndex { $0.record.tag == tag } ?? children.endIndex
        guard let index = children[..<end].firstIndex(where: { $0.record.tag == HwpTag.listHeader }) else {
            return nil
        }
        let header = children[index].record.payload
        guard header.count >= 18 else {
            return nil
        }
        let sides: [HwpDocument.Caption.Side] = [.left, .right, .top, .bottom]
        let count = Int(header.uint16(at: 0))
        return HwpDocument.Caption(
            side: sides[Int(header.uint32(at: 8) & 3)],
            width: Int(header.uint32(at: 12)),
            gap: Int(header.uint16(at: 16)),
            paragraphs: paragraphs(in: children[(index + 1)..<end].prefix { $0.record.tag == HwpTag.paraHeader }.prefix(count))
        )
    }

    private func table(_ node: RecordNode) -> HwpDocument.Table? {
        var table = HwpDocument.Table()
        table.layout = Self.objectLayout(node.record.payload)
        let children = node.children
        guard let recordIndex = children.firstIndex(where: { $0.record.tag == HwpTag.table }) else {
            return nil
        }
        let record = children[recordIndex]
        table.layout.caption = caption(in: children, before: HwpTag.table)
        var reader = ByteReader(record.record.payload)
        let flags = reader.uint32()
        table.repeatHeader = flags & 4 != 0
        table.rows = Int(reader.uint16())
        table.columns = Int(reader.uint16())
        table.cellSpacing = Int(reader.uint16())
        table.padding = (Int(reader.uint16()), Int(reader.uint16()), Int(reader.uint16()), Int(reader.uint16()))
        reader.skip(table.rows * 2)
        table.borderFillID = Int(reader.uint16())

        var index = recordIndex + 1
        while index < children.endIndex {
            defer {
                index += 1
            }
            guard children[index].record.tag == HwpTag.listHeader else {
                continue
            }
            let header = children[index].record.payload
            let count = Int(header.uint16(at: 0))
            var cell = HwpDocument.Table.Cell()
            cell.verticalAlign = Int(header.uint32(at: 4) >> 5 & 3)
            cell.column = Int(header.uint16(at: 8))
            cell.row = Int(header.uint16(at: 10))
            cell.columnSpan = max(Int(header.uint16(at: 12)), 1)
            cell.rowSpan = max(Int(header.uint16(at: 14)), 1)
            // Some files store a small negative size, which read unsigned makes a row tall enough to hang pagination.
            cell.width = max(Int(header.int32(at: 16)), 0)
            cell.height = max(Int(header.int32(at: 20)), 0)
            cell.padding = (Int(header.uint16(at: 24)), Int(header.uint16(at: 26)), Int(header.uint16(at: 28)), Int(header.uint16(at: 30)))
            cell.borderFillID = Int(header.uint16(at: 32))
            let paragraphNodes = children[(index + 1)...].prefix { $0.record.tag == HwpTag.paraHeader }.prefix(count)
            cell.paragraphs = paragraphs(in: paragraphNodes)
            table.cells.append(cell)
            index += paragraphNodes.count
        }
        return table
    }

    /// A 'gso ' drawing object: its SHAPE_COMPONENT says what it is.
    private func shapeObject(_ node: RecordNode, layout: HwpDocument.ObjectLayout) -> HwpDocument.Control? {
        guard let component = node.children.first(where: { $0.record.tag == HwpTag.shapeComponent }) else {
            return nil
        }
        return shapeComponent(component, layout: layout, topLevel: true, parent: (0, 0))
    }

    /// - Parameter parent: The enclosing group's corner in the top group's space, for a component
    ///   inside a group.
    private func shapeComponent(
        _ node: RecordNode,
        layout: HwpDocument.ObjectLayout,
        topLevel: Bool,
        parent: (x: Int, y: Int)
    ) -> HwpDocument.Control? {
        let payload = node.record.payload
        let base = topLevel ? 8 : 4
        let kind = Self.controlID(payload)
        let matrixCount = Int(payload.uint16(at: base + 42))
        var layout = layout
        var corner = (x: 0, y: 0)
        if !topLevel {
            // A caption belongs to the group, not its parts.
            layout.caption = nil
            let size = (width: Double(payload.uint32(at: base + 12)), height: Double(payload.uint32(at: base + 16)))
            var transform = CGAffineTransform.identity
            for index in (0..<matrixCount).reversed() {
                transform = transform
                    .concatenating(Self.matrix(payload, at: base + 140 + index * 96))
                    .concatenating(Self.matrix(payload, at: base + 92 + index * 96))
            }
            transform = transform.concatenating(Self.matrix(payload, at: base + 44))
            let box = CGRect(x: 0, y: 0, width: size.width, height: size.height).applying(transform)
            corner = (Int(box.minX.rounded()), Int(box.minY.rounded()))
            layout.inline = false
            layout.x = corner.x - parent.x
            layout.y = corner.y - parent.y
            layout.width = Int(box.width.rounded())
            layout.height = Int(box.height.rounded())
        }
        
        var reader = ByteReader(payload)
        reader.skip(base + 44 + 48 + matrixCount * 96)
        let lineColor = reader.uint32()
        let lineWidth = Int(reader.int32())
        let lineFlags = reader.uint32()
        var line = HwpDocument.Border.none
        if lineWidth > 0, lineFlags & 0x3F != 0 || lineColor >> 24 == 0 {
            line = HwpDocument.Border(
                style: HwpDocument.Border.Style(code: Int(lineFlags & 0x3F)) ?? .solid,
                width: Double(lineWidth) / 283.465,
                color: HwpDocument.Color(colorRef: lineColor) ?? .black
            )
            if lineFlags & 0x3F == 0 { line = .none }
        }
        reader.skip(1)
        let fill = Self.fill(&reader)

        switch kind {
        case "$pic":
            guard let picture = node.children.first(where: { $0.record.tag == HwpTag.shapeComponentPicture }) else {
                return nil
            }
            let data = picture.record.payload
            var result = HwpDocument.Picture()
            result.layout = layout
            result.binID = Int(data.uint16(at: 71))
            result.crop = (Int(data.int32(at: 44)), Int(data.int32(at: 48)), Int(data.int32(at: 52)), Int(data.int32(at: 56)))
            result.extent = (Int(data.int32(at: 28)), Int(data.int32(at: 32)))
            result.effect = HwpDocument.Picture.Effect(code: data.count > 70 ? Int(data[data.startIndex + 70]) : 0)
            result.border = line
            return .picture(result)
        case "$con":
            var shape = HwpDocument.Shape(layout: layout)
            shape.children = node.children
                .filter { $0.record.tag == HwpTag.shapeComponent }
                .compactMap { shapeComponent($0, layout: layout, topLevel: false, parent: corner) }
            return .shape(shape)
        default:
            var shape = HwpDocument.Shape(layout: layout, line: line, fill: fill.color, image: fill.image)
            if let geometry = node.children.first(where: {
                [HwpTag.shapeComponentLine, HwpTag.shapeComponentRectangle, HwpTag.shapeComponentEllipse].contains($0.record.tag)
            }) {
                let data = geometry.record.payload
                switch geometry.record.tag {
                case HwpTag.shapeComponentLine:
                    shape.kind = .line
                    shape.start = (Int(data.int32(at: 0)), Int(data.int32(at: 4)))
                    shape.end = (Int(data.int32(at: 8)), Int(data.int32(at: 12)))
                case HwpTag.shapeComponentRectangle:
                    shape.kind = .rectangle
                    shape.cornerRatio = Int(data.first ?? 0)
                default:
                    shape.kind = .ellipse
                }
            }
            if let listIndex = node.children.firstIndex(where: { $0.record.tag == HwpTag.listHeader }) {
                let header = node.children[listIndex].record.payload
                shape.textVerticalAlign = Int(header.uint32(at: 4) >> 5 & 3)
                shape.textPadding = (Int(header.uint16(at: 8)), Int(header.uint16(at: 10)), Int(header.uint16(at: 12)), Int(header.uint16(at: 14)))
                shape.text = paragraphs(in: node.children[(listIndex + 1)...])
            }
            return .shape(shape)
        }
    }
}

/// A record with the records nested under it by level.
struct RecordNode {
    let record: HwpRecord
    var children: [RecordNode]

    static func tree(_ records: [HwpRecord]) -> [RecordNode] {
        var index = 0
        return children(of: -1, in: records, index: &index)
    }

    private static func children(of level: Int, in records: [HwpRecord], index: inout Int) -> [RecordNode] {
        var result: [RecordNode] = []
        while index < records.count, records[index].level > level {
            let record = records[index]
            index += 1
            result.append(RecordNode(record: record, children: children(of: record.level, in: records, index: &index)))
        }
        return result
    }
}

/// Little-endian cursor over a record payload; reads past the end return zero.
struct ByteReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { max(data.count - offset, 0) }

    mutating func skip(_ count: Int) { offset += count }

    mutating func uint8() -> UInt8 {
        defer {
            offset += 1
        }
        return offset < data.count ? data[data.startIndex + offset] : 0
    }

    mutating func int8() -> Int8 { Int8(bitPattern: uint8()) }

    mutating func uint16() -> UInt16 {
        defer {
            offset += 2
        }
        return data.uint16(at: offset)
    }

    mutating func int16() -> Int16 { Int16(bitPattern: uint16()) }

    mutating func uint32() -> UInt32 {
        defer {
            offset += 4
        }
        return data.uint32(at: offset)
    }

    mutating func int32() -> Int32 { Int32(bitPattern: uint32()) }

    /// A WORD length followed by that many UTF-16 units.
    mutating func string() -> String {
        let length = Int(uint16())
        let units = (0..<length).map { _ in uint16() }
        return String(decoding: units, as: UTF16.self)
    }
}
