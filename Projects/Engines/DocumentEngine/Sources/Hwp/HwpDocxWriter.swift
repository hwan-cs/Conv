import Foundation
import ImageIO
import ZIPFoundation

/// Writes an `HwpDocument` as a Word document, to be edited rather than to look exactly the same:
/// Word breaks lines and pages itself, so only the content and its formatting carry over.
///
/// Paragraph and character shapes become direct formatting; numbers and bullets their text, as
/// Hangul counted them; tables keep their grid, merges, borders and fills; pictures, boxes and
/// groups become DrawingML, in line or anchored where Hangul placed them; equations become Office
/// math. Headers, footers, page numbers, footnotes and endnotes go to their own parts.
///
/// Lengths: HWPUNIT is 1/7200 inch, so twips are a fifth of it and EMUs 127 times it.
struct HwpDocxWriter {
    private let document: HwpDocument
    private var headings: HwpHeadings
    private var relationships: [Relationship] = []
    private var parts: [(path: String, data: Data)] = []
    private var contentTypes: [(part: String, type: String)] = []
    private var images: [Int: (id: String, size: CGSize?)] = [:]
    private var footnotes: [String] = []
    private var endnotes: [String] = []
    private var headerCount = 0
    private var footerCount = 0
    private var hasEvenHeaders = false
    private var drawingID = 0
    /// Inside a note, where its number is the note's own reference mark.
    private var inNote = false
    private var isLinkOpen = false
    /// Off inside text boxes and layout tables, where Word can't float a table.
    private var floatsTables = true

    private struct Relationship {
        var id: String
        var type: String
        var target: String
        var isExternal = false
    }

    init(document: HwpDocument) {
        self.document = document
        headings = HwpHeadings(document: document)
    }

    // MARK: Package

    mutating func write(to url: URL) throws {
        let body = body()
        var settingsNotes = ""
        if !footnotes.isEmpty {
            let separators = Self.noteSeparators("footnote")
            add(part: "word/footnotes.xml", xml: "<w:footnotes \(Self.namespaces)>\(separators)\(footnotes.joined())</w:footnotes>",
                type: "application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml",
                relationship: "footnotes", target: "footnotes.xml")
            settingsNotes += "<w:footnotePr><w:footnote w:id=\"-1\"/><w:footnote w:id=\"0\"/></w:footnotePr>"
        }
        if !endnotes.isEmpty {
            let separators = Self.noteSeparators("endnote")
            add(part: "word/endnotes.xml", xml: "<w:endnotes \(Self.namespaces)>\(separators)\(endnotes.joined())</w:endnotes>",
                type: "application/vnd.openxmlformats-officedocument.wordprocessingml.endnotes+xml",
                relationship: "endnotes", target: "endnotes.xml")
            settingsNotes += "<w:endnotePr><w:endnote w:id=\"-1\"/><w:endnote w:id=\"0\"/></w:endnotePr>"
        }
        add(part: "word/styles.xml", xml: Self.styles(document),
            type: "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml",
            relationship: "styles", target: "styles.xml")
        let tab = (document.sections.first?.defaultTab ?? 4000) / 5
        add(part: "word/settings.xml", xml: """
            <w:settings \(Self.namespaces)><w:zoom w:percent="100"/><w:defaultTabStop w:val="\(tab)"/>\
            \(hasEvenHeaders ? "<w:evenAndOddHeaders/>" : "")<w:characterSpacingControl w:val="doNotCompress"/>\(settingsNotes)\
            <w:compat><w:doNotExpandShiftReturn/><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>
            """,
            type: "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml",
            relationship: "settings", target: "settings.xml")
        parts.append(("word/document.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document \(Self.namespaces)><w:body>\(body)</w:body></w:document>".utf8)))

        let rels = relationships.map { relationship in
            let mode = relationship.isExternal ? " TargetMode=\"External\"" : ""
            return "<Relationship Id=\"\(relationship.id)\" Type=\"\(relationship.type)\" Target=\"\(Self.escape(relationship.target))\"\(mode)/>"
        }.joined()
        parts.append(("word/_rels/document.xml.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>".utf8)))
        parts.append(("_rels/.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """.utf8)))
        let overrides = ([("/word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml")] + contentTypes)
            .map { "<Override PartName=\"\($0.0)\" ContentType=\"\($0.1)\"/>" }.joined()
        parts.append(("[Content_Types].xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\
            <Default Extension="jpeg" ContentType="image/jpeg"/><Default Extension="gif" ContentType="image/gif"/>\(overrides)</Types>
            """.utf8)))

        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        for part in parts {
            let data = part.data
            try archive.addEntry(with: part.path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    private mutating func add(part path: String, xml: String, type: String, relationship: String, target: String) {
        parts.append((path, Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\(xml)".utf8)))
        contentTypes.append(("/" + path, type))
        _ = relate("http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(relationship)", target: target)
    }

    private mutating func relate(_ type: String, target: String, external: Bool = false) -> String {
        let id = "rId\(relationships.count + 1)"
        relationships.append(Relationship(id: id, type: type, target: target, isExternal: external))
        return id
    }

    static let namespaces = [
        "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"",
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"",
        "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\"",
        "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"",
        "xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"",
        "xmlns:wps=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\"",
        "xmlns:wpg=\"http://schemas.microsoft.com/office/word/2010/wordprocessingGroup\"",
        "xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\"",
        "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"",
        "mc:Ignorable=\"wps wpg\"",
    ].joined(separator: " ")

    private static func noteSeparators(_ kind: String) -> String {
        "<w:\(kind) w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:\(kind)>"
            + "<w:\(kind) w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:\(kind)>"
    }

    /// Word's defaults with no space after paragraphs and no extra space between Hangul and Latin,
    /// which Hangul doesn't add either.
    private static func styles(_ document: HwpDocument) -> String {
        let face = escape(document.fonts[0].first?.name ?? "함초롬바탕")
        return """
            <w:styles \(namespaces)><w:docDefaults><w:rPrDefault><w:rPr>\
            <w:rFonts w:ascii="\(face)" w:eastAsia="\(face)" w:hAnsi="\(face)" w:cs="\(face)"/>\
            <w:sz w:val="20"/><w:szCs w:val="20"/><w:lang w:val="en-US" w:eastAsia="ko-KR"/></w:rPr></w:rPrDefault>\
            <w:pPrDefault><w:pPr><w:autoSpaceDE w:val="0"/><w:autoSpaceDN w:val="0"/><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
            <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
            <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/>\
            <w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="0" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="0" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
            </w:styles>
            """
    }

    // MARK: Sections

    private mutating func body() -> String {
        var xml = ""
        for (index, section) in document.sections.enumerated() {
            headings.outlineNumberingID = section.outlineNumberingID
            var blocks = section.paragraphs.flatMap { self.blocks($0) }
            if index == document.sections.count - 1 {
                // Hangul gathers endnotes at the document's end; Word does the same by default.
                if blocks.isEmpty { blocks = ["<w:p/>"] }
                xml += blocks.joined() + sectionProperties(section)
            } else {
                xml += blocks.joined() + "<w:p><w:pPr>\(sectionProperties(section))</w:pPr></w:p>"
            }
        }
        return xml
    }

    private mutating func sectionProperties(_ section: HwpDocument.Section) -> String {
        var references = ""
        var headers: [HwpDocument.HeaderFooter] = []
        var footers: [HwpDocument.HeaderFooter] = []
        var pageNumber: HwpDocument.PageNumberPosition?
        var firstPageHides: (header: Bool, footer: Bool)?
        for (index, paragraph) in section.paragraphs.enumerated() {
            for case .control(let control) in paragraph.content {
                switch control {
                case .header(let header):
                    headers.append(header)
                case .footer(let footer):
                    footers.append(footer)
                case .pageNumberPosition(let position) where position.position != 0:
                    pageNumber = position
                case .pageHide(let header, let footer, _) where index < 3:
                    firstPageHides = (header, footer)
                default: break
                }
            }
        }
        if let pageNumber {
            let paragraph = pageNumberParagraph(pageNumber)
            if (1...3).contains(pageNumber.position) || [7, 9].contains(pageNumber.position) {
                if headers.isEmpty {
                    references += reference("header", content: paragraph, pages: .both)
                }
            } else if footers.isEmpty {
                references += reference("footer", content: paragraph, pages: .both)
            }
        }
        var firstHeader = "", firstFooter = ""
        for header in headers {
            let content = header.paragraphs.flatMap { blocks($0) }.joined()
            references += reference("header", content: content, pages: header.pages)
            if header.pages != .even {
                firstHeader = content
            }
        }
        for footer in footers {
            let content = footer.paragraphs.flatMap { blocks($0) }.joined()
            references += reference("footer", content: content, pages: footer.pages)
            if footer.pages != .even {
                firstFooter = content
            }
        }
        var titlePage = ""
        if let hides = firstPageHides, hides.header || hides.footer {
            references += reference("header", content: hides.header ? "" : firstHeader, pages: nil)
            references += reference("footer", content: hides.footer ? "" : firstFooter, pages: nil)
            titlePage = "<w:titlePg/>"
        }
        let page = section.page
        let orientation = page.width > page.height ? " w:orient=\"landscape\"" : ""
        let start = section.pageNumberStart > 0 ? "<w:pgNumType w:start=\"\(section.pageNumberStart)\"/>" : ""
        let columns = section.columns > 1 ? "<w:cols w:num=\"\(section.columns)\" w:space=\"\(section.columnGap / 5)\"/>" : "<w:cols w:space=\"425\"/>"

        return "<w:sectPr>\(references)<w:pgSz w:w=\"\(page.width / 5)\" w:h=\"\(page.height / 5)\"\(orientation)/>"
            + "<w:pgMar w:top=\"\((page.top + page.header) / 5)\" w:right=\"\(page.right / 5)\" w:bottom=\"\((page.bottom + page.footer) / 5)\" "
            + "w:left=\"\(page.left / 5)\" w:header=\"\(page.top / 5)\" w:footer=\"\(page.bottom / 5)\" w:gutter=\"\(page.gutter / 5)\"/>"
            + "\(start)\(columns)\(titlePage)</w:sectPr>"
    }

    /// - Parameter pages: Nil for the first page's.
    private mutating func reference(_ kind: String, content: String, pages: HwpDocument.HeaderFooter.Pages?) -> String {
        let number: Int
        if kind == "header" {
            headerCount += 1
            number = headerCount
        } else {
            footerCount += 1
            number = footerCount
        }
        let tag = kind == "header" ? "hdr" : "ftr"
        let name = "\(kind)\(number).xml"
        parts.append(("word/\(name)", Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:\(tag) \(Self.namespaces)>\(content.isEmpty ? "<w:p/>" : content)</w:\(tag)>".utf8)))
        contentTypes.append(("/word/\(name)", "application/vnd.openxmlformats-officedocument.wordprocessingml.\(kind)+xml"))
        let id = relate("http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(kind)", target: name)
        let type: String
        switch pages {
        case nil: 
            type = "first"
        case .both, .odd: 
            type = "default"
        case .even:
            type = "even"
            hasEvenHeaders = true
        }
        return "<w:\(kind)Reference w:type=\"\(type)\" r:id=\"\(id)\"/>"
    }

    private func pageNumberParagraph(_ position: HwpDocument.PageNumberPosition) -> String {
        let alignment = switch position.position {
        case 1, 4, 9, 10: 
            "left"
        case 3, 6, 7, 8: 
            "right"
        default: 
            "center"
        }
        let format = switch position.style {
        case 2: 
            " \\* ROMAN"
        case 3: 
            " \\* roman"
        default: 
            ""
        }
        let before = position.dash.isEmpty ? position.prefix : position.dash + " "
        let after = position.dash.isEmpty ? position.suffix : " " + position.dash
        var runs = before.isEmpty ? "" : "<w:r><w:t xml:space=\"preserve\">\(Self.escape(before))</w:t></w:r>"
        runs += "<w:fldSimple w:instr=\"PAGE\(format)\"><w:r><w:t>1</w:t></w:r></w:fldSimple>"
        if !after.isEmpty { runs += "<w:r><w:t xml:space=\"preserve\">\(Self.escape(after))</w:t></w:r>" }
        return "<w:p><w:pPr><w:jc w:val=\"\(alignment)\"/></w:pPr>\(runs)</w:p>"
    }

    // MARK: Paragraphs
    private mutating func blocks(_ paragraph: HwpDocument.Paragraph) -> [String] {
        let shape = document.paraShapes[safe: paragraph.paraShapeID] ?? HwpDocument.ParaShape()
        var blocks: [String] = []
        var runs = ""
        var hasObject = false
        var hasText = false
        if paragraph.pageBreak {
            runs += "<w:r><w:br w:type=\"page\"/></w:r>"
        }
        if paragraph.columnBreak {
            runs += "<w:r><w:br w:type=\"column\"/></w:r>"
        }
        if let (label, spacing) = headings.head(shape.heading) {
            let shapeID = spacing.charShapeID.flatMap { document.charShapes.indices.contains($0) ? $0 : nil } ?? paragraph.charShapeID
            runs += run(label, shapeID: shapeID) + run(" ", shapeID: shapeID)
            hasText = true
        }
        let tables = paragraph.content.compactMap { inline -> HwpDocument.Table? in
            if case .control(.table(let table)) = inline {
                return table
            }
            return nil
        }
        let sideBySide = tables.count > 1 && Self.areSideBySide(tables)
        var placedSideBySide = false
        var atLineStart = false
        var afterObject = false
        func flush(_ writer: inout HwpDocxWriter, force: Bool) {
            if writer.isLinkOpen {
                runs += "</w:hyperlink>"
                writer.isLinkOpen = false
            }
            guard force || !runs.isEmpty else {
                return
            }
            blocks.append("<w:p>\(writer.paragraphProperties(shape, paragraph: paragraph, hasObject: hasObject))\(runs)</w:p>")
            runs = ""
            hasObject = false
        }
        func breakBefore(_ layout: HwpDocument.ObjectLayout) {
            if layout.inline, atLineStart, hasText {
                runs += "<w:r><w:br/></w:r>"
            }
            atLineStart = false
            afterObject = layout.inline
        }
        for inline in paragraph.content {
            if case .lineStart = inline {
                if afterObject {
                    runs += "<w:r><w:br/></w:r>"
                }
                atLineStart = true
                afterObject = false
                continue
            }
            if case .control(.picture) = inline {
                
            } else if case .control(.shape) = inline {
                
            } else {
                atLineStart = false
                afterObject = false
            }
            switch inline {
            case .text(let text, let shapeID):
                runs += run(text, shapeID: shapeID)
                hasText = true
            case .tab(let shapeID):
                runs += "<w:r>\(runProperties(shapeID))<w:tab/></w:r>"
            case .lineBreak:
                runs += "<w:r><w:br/></w:r>"
            case .lineStart:
                break
            case .control(let control):
                switch control {
                case .table(let table):
                    if !runs.isEmpty {
                        flush(&self, force: false)
                    }
                    if !sideBySide {
                        blocks += captionBlocks(table.layout, above: true)
                        blocks.append(self.table(table))
                        blocks += captionBlocks(table.layout, above: false)
                    } else if !placedSideBySide {
                        blocks.append(layoutTable(tables))
                        placedSideBySide = true
                    }
                case .picture(let picture):
                    if picture.layout.caption.map(Self.isAbove) == true {
                        flush(&self, force: false)
                        blocks += captionBlocks(picture.layout, above: true)
                    }
                    breakBefore(picture.layout)
                    if let drawing = drawing(picture) {
                        runs += "<w:r>\(drawing)</w:r>"
                    }
                    hasObject = true
                    if picture.layout.caption.map(Self.isAbove) == false {
                        flush(&self, force: false)
                        blocks += captionBlocks(picture.layout, above: false)
                    }
                case .shape(let shape):
                    if shape.layout.caption.map(Self.isAbove) == true {
                        flush(&self, force: false)
                        blocks += captionBlocks(shape.layout, above: true)
                    }
                    breakBefore(shape.layout)
                    runs += "<w:r>\(drawing(shape))</w:r>"
                    hasObject = true
                    if shape.layout.caption.map(Self.isAbove) == false {
                        flush(&self, force: false)
                        blocks += captionBlocks(shape.layout, above: false)
                    }
                case .equation(let equation):
                    if equation.layout.caption.map(Self.isAbove) == true {
                        flush(&self, force: false)
                        blocks += captionBlocks(equation.layout, above: true)
                    }
                    runs += HwpOfficeMath.omml(HwpEquation.mathML(equation.script), size: equation.fontSize)
                    hasObject = true
                    if equation.layout.caption.map(Self.isAbove) == false {
                        flush(&self, force: false)
                        blocks += captionBlocks(equation.layout, above: false)
                    }
                case .footnote(let paragraphs):
                    runs += note(paragraphs, kind: "footnote", shapeID: paragraph.charShapeID)
                case .endnote(let paragraphs):
                    runs += note(paragraphs, kind: "endnote", shapeID: paragraph.charShapeID)
                case .autoNumber(let number):
                    runs += autoNumber(number)
                case .hyperlink(let target):
                    if isLinkOpen {
                        runs += "</w:hyperlink>"
                    }
                    let id = relate("http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target: target, external: true)
                    runs += "<w:hyperlink r:id=\"\(id)\">"
                    isLinkOpen = true
                case .fieldEnd:
                    if isLinkOpen {
                        runs += "</w:hyperlink>"
                        isLinkOpen = false
                    }
                case .header, .footer, .pageNumberPosition, .pageHide:
                    break
                }
            }
        }
        flush(&self, force: blocks.isEmpty || hasText)
        return blocks
    }

    /// Word has no object captions, so they become paragraphs around the object.
    private static func isAbove(_ caption: HwpDocument.Caption) -> Bool {
        caption.side == .top || caption.side == .left
    }

    private mutating func captionBlocks(_ layout: HwpDocument.ObjectLayout, above: Bool) -> [String] {
        guard let caption = layout.caption, Self.isAbove(caption) == above else {
            return []
        }
        return caption.paragraphs.flatMap { blocks($0) }
    }

    private func paragraphProperties(_ shape: HwpDocument.ParaShape, paragraph: HwpDocument.Paragraph, hasObject: Bool) -> String {
        var xml = ""
        if shape.pageBreakBefore { xml += "<w:pageBreakBefore/>" }
        if let id = shape.borderFillID, let fill = document.borderFills[safe: id - 1] {
            let sides = [("top", fill.top), ("left", fill.left), ("bottom", fill.bottom), ("right", fill.right)]
            if sides.contains(where: { $0.1.style != nil }) {
                xml += "<w:pBdr>" + sides.map { Self.border($0.0, $0.1) }.joined() + "</w:pBdr>"
            }
            if let color = fill.fill { xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(Self.hex(color))\"/>" }
        }
        if let tabDef = document.tabDefs[safe: shape.tabDefID], !tabDef.stops.isEmpty {
            xml += "<w:tabs>" + tabDef.stops.map { stop in
                let kind = switch stop.kind {
                case .left: 
                    "left"
                case .right: 
                    "right"
                case .center: 
                    "center"
                case .decimal: 
                    "decimal"
                }
                return "<w:tab w:val=\"\(kind)\"\(stop.leader ? " w:leader=\"dot\"" : "") w:pos=\"\(stop.position / 5)\"/>"
            }.joined() + "</w:tabs>"
        }
        xml += "<w:spacing w:before=\"\(max(shape.spaceBefore, 0) / 5)\" w:after=\"\(max(shape.spaceAfter, 0) / 5)\" \(lineSpacing(shape.lineSpacing, paragraph: paragraph, hasObject: hasObject))/>"
        // A negative indent hangs the lines after the first (내어쓰기).
        let left = shape.left - min(shape.indent, 0)
        let first = shape.indent >= 0 ? "w:firstLine=\"\(shape.indent / 5)\"" : "w:hanging=\"\(-shape.indent / 5)\""
        xml += "<w:ind w:left=\"\(left / 5)\" w:right=\"\(shape.right / 5)\" \(first)/>"
        let alignment = switch shape.alignment {
        case .justify, .divide: 
            "both"
        case .left: 
            "left"
        case .right: 
            "right"
        case .center: 
            "center"
        case .distribute: 
            "distribute"
        }
        xml += "<w:jc w:val=\"\(alignment)\"/>"
        return "<w:pPr>\(xml)</w:pPr>"
    }

    /// Hangul's percent is of the font size; Word's "multiple" is of the face's own, taller line,
    /// so a percent becomes an at-least height in points. Exact heights would clip objects.
    private func lineSpacing(_ spacing: HwpDocument.ParaShape.LineSpacing, paragraph: HwpDocument.Paragraph, hasObject: Bool) -> String {
        let height = paragraph.content.reduce(document.charShapes[safe: paragraph.charShapeID]?.height ?? 1000) { tallest, inline in
            if case .text(_, let id) = inline {
                return max(tallest, document.charShapes[safe: id]?.height ?? 0)
            }
            return tallest
        }
        let rule = hasObject ? "atLeast" : "exact"
        switch spacing {
        case .percent(let percent):
            return "w:line=\"\(height * percent / 100 / 5)\" w:lineRule=\"\(percent < 130 ? rule : "atLeast")\""
        case .fixed(let value):
            return "w:line=\"\(value / 5)\" w:lineRule=\"\(rule)\""
        case .atLeast(let value):
            return "w:line=\"\(value / 5)\" w:lineRule=\"atLeast\""
        case .betweenLines(let gap):
            return "w:line=\"\((height + gap) / 5)\" w:lineRule=\"atLeast\""
        }
    }

    // MARK: Runs
    private func run(_ text: String, shapeID: Int) -> String {
        let clean = Self.escape(text.filter { $0 != "\u{200B}" })
        guard !clean.isEmpty else {
            return ""
        }
        return "<w:r>\(runProperties(shapeID))<w:t xml:space=\"preserve\">\(clean)</w:t></w:r>"
    }

    private func runProperties(_ id: Int, superscript: Bool = false) -> String {
        guard let shape = document.charShapes[safe: id] else {
            return ""
        }
        var xml = ""
        let hangul = document.fonts[0][safe: shape.faces[0]]?.name
        let latin = document.fonts[1][safe: shape.faces[1]]?.name ?? hangul
        if let hangul, let latin {
            xml += "<w:rFonts w:ascii=\"\(Self.escape(latin))\" w:hAnsi=\"\(Self.escape(latin))\" w:eastAsia=\"\(Self.escape(hangul))\" w:cs=\"\(Self.escape(latin))\"/>"
        }
        if shape.bold {
            xml += "<w:b/><w:bCs/>"
        }
        if shape.italic {
            xml += "<w:i/><w:iCs/>"
        }
        if shape.strikeout {
            xml += "<w:strike/>"
        }
        if shape.color != .black {
            xml += "<w:color w:val=\"\(Self.hex(shape.color))\"/>"
        }
        let size = shape.height * shape.relativeSizes[0] / 100
        let spacing = shape.spacings[0] * size / 500
        if spacing != 0 {
            xml += "<w:spacing w:val=\"\(spacing)\"/>"
        }
        if shape.ratios[0] != 100 {
            xml += "<w:w w:val=\"\(min(max(shape.ratios[0], 1), 600))\"/>"
        }
        xml += "<w:sz w:val=\"\(max(size / 50, 1))\"/><w:szCs w:val=\"\(max(size / 50, 1))\"/>"
        if shape.underline != nil {
            xml += "<w:u w:val=\"single\"/>"
        }
        if let shade = shape.shadeColor, shade != Self.white {
            xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(Self.hex(shade))\"/>"
        }
        if superscript || shape.isSuperscript {
            xml += "<w:vertAlign w:val=\"superscript\"/>"
        } else if shape.isSubscript {
            xml += "<w:vertAlign w:val=\"subscript\"/>"
        }
        return "<w:rPr>\(xml)</w:rPr>"
    }

    private static let white = HwpDocument.Color(red: 255, green: 255, blue: 255)

    private mutating func autoNumber(_ number: HwpDocument.AutoNumber) -> String {
        let properties = runProperties(number.charShapeID)
        switch number.kind {
        case .page:
            return "<w:fldSimple w:instr=\"PAGE\"><w:r>\(properties)<w:t>1</w:t></w:r></w:fldSimple>"
        case .totalPages:
            return "<w:fldSimple w:instr=\"NUMPAGES\"><w:r>\(properties)<w:t>1</w:t></w:r></w:fldSimple>"
        case .footnote where inNote:
            return "<w:r>\(runProperties(number.charShapeID, superscript: true))<w:footnoteRef/></w:r>"
        case .endnote where inNote:
            return "<w:r>\(runProperties(number.charShapeID, superscript: true))<w:endnoteRef/></w:r>"
        case .footnote, .endnote:
            return ""
        case .picture, .table, .equation:
            return run(HwpHTMLWriter.format(number.number, style: number.style), shapeID: number.charShapeID)
        }
    }

    /// The note's text goes to its part; the body keeps the reference mark.
    private mutating func note(_ paragraphs: [HwpDocument.Paragraph], kind: String, shapeID: Int) -> String {
        let outer = inNote
        inNote = true
        let content = paragraphs.flatMap { blocks($0) }.joined()
        inNote = outer
        let isFootnote = kind == "footnote"
        let id = (isFootnote ? footnotes.count : endnotes.count) + 1
        let mark = isFootnote ? "<w:footnoteRef/>" : "<w:endnoteRef/>"

        let hasMark = content.contains(mark)
        let markRun = "<w:r>\(runProperties(shapeID, superscript: true))\(mark)</w:r>"
        let body = hasMark ? content : content.replacingOccurrences(of: "</w:pPr>", with: "</w:pPr>\(markRun)", options: [], range: content.range(of: "</w:pPr>"))
        let part = "<w:\(kind) w:id=\"\(id)\">\(body.isEmpty ? "<w:p>\(markRun)</w:p>" : body)</w:\(kind)>"
        if isFootnote {
            footnotes.append(part)
        } else {
            endnotes.append(part)
        }
        return "<w:r>\(runProperties(shapeID, superscript: true))<w:\(kind)Reference w:id=\"\(id)\"/></w:r>"
    }

    // MARK: Tables
    private mutating func table(_ table: HwpDocument.Table) -> String {
        let widths = HwpHTMLWriter.columnWidths(table)
        var origins: [[HwpDocument.Table.Cell?]] = Array(repeating: Array(repeating: nil, count: max(table.columns, 1)), count: max(table.rows, 1))
        for cell in table.cells where table.rows > cell.row && table.columns > cell.column {
            for row in cell.row..<min(cell.row + cell.rowSpan, table.rows) {
                for column in cell.column..<min(cell.column + cell.columnSpan, table.columns) {
                    origins[row][column] = cell
                }
            }
        }
        var xml = "<w:tbl><w:tblPr>"
        let layout = table.layout

        let floats = !layout.inline && floatsTables && [.square, .tight, .through].contains(layout.wrap) && layout.height < 30000
        if floats {
            let horizontal = switch layout.horizontal {
            case .paper: 
                "page"
            case .page: 
                "margin"
            case .column, .paragraph: 
                "text"
            }
            let vertical = switch layout.vertical {
            case .paper: 
                "page"
            case .page, .column: 
                "margin"
            case .paragraph: 
                "text"
            }
            let x = switch layout.horizontalAlign {
            case 1: 
                "w:tblpXSpec=\"center\""
            case 2: 
                "w:tblpXSpec=\"right\""
            default: 
                "w:tblpX=\"\(layout.x / 5)\""
            }
            let margins = layout.margins
            xml += "<w:tblpPr w:leftFromText=\"\(margins.left / 5)\" w:rightFromText=\"\(margins.right / 5)\" w:topFromText=\"\(margins.top / 5)\" "
                + "w:bottomFromText=\"\(margins.bottom / 5)\" w:vertAnchor=\"\(vertical)\" w:horzAnchor=\"\(horizontal)\" \(x) w:tblpY=\"\(layout.y / 5)\"/>"
        }
        xml += "<w:tblW w:w=\"\(widths.reduce(0, +) / 5)\" w:type=\"dxa\"/>"
        if table.layout.horizontalAlign == 1 && !floats {
            xml += "<w:jc w:val=\"center\"/>"
        }
        if table.cellSpacing > 0 {
            xml += "<w:tblCellSpacing w:w=\"\(table.cellSpacing / 5)\" w:type=\"dxa\"/>"
        }
        xml += "<w:tblLayout w:type=\"fixed\"/><w:tblCellMar>\(Self.margins(table.padding))</w:tblCellMar></w:tblPr>"
        xml += "<w:tblGrid>" + widths.map { "<w:gridCol w:w=\"\(max($0 / 5, 1))\"/>" }.joined() + "</w:tblGrid>"
        for row in 0..<max(table.rows, 1) {
            let height = table.cells.filter { $0.row == row && $0.rowSpan == 1 }.map(\.height).min()
            xml += "<w:tr><w:trPr>"
            if let height, height > 0 {
                xml += "<w:trHeight w:val=\"\(height / 5)\" w:hRule=\"atLeast\"/>"
            }
            xml += "</w:trPr>"
            var column = 0
            while column < max(table.columns, 1) {
                guard let cell = origins[row][column], cell.column == column else {
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(widths[safe: column].map { $0 / 5 } ?? 0)\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
                    column += 1
                    continue
                }
                let span = min(cell.columnSpan, table.columns - column)
                let width = widths[column..<column + span].reduce(0, +)
                var properties = "<w:tcW w:w=\"\(width / 5)\" w:type=\"dxa\"/>"
                if span > 1 {
                    properties += "<w:gridSpan w:val=\"\(span)\"/>"
                }
                let isFirstRow = cell.row == row
                if cell.rowSpan > 1 {
                    properties += isFirstRow ? "<w:vMerge w:val=\"restart\"/>" : "<w:vMerge/>"
                }
                let fill = document.borderFills[safe: cell.borderFillID - 1]
                if let fill {
                    properties += "<w:tcBorders>" + [("top", fill.top), ("left", fill.left), ("bottom", fill.bottom), ("right", fill.right)].map { Self.border($0.0, $0.1) }.joined() + "</w:tcBorders>"
                    if let color = fill.fill {
                        properties += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(Self.hex(color))\"/>"
                    }
                }
                let text = cell.paragraphs.flatMap(\.content).reduce(into: "") { text, inline in
                    if case .text(let string, _) = inline { text += string }
                }
                let isLabel = !text.isEmpty && text.trimmingCharacters(in: .whitespaces).count <= 3
                if isLabel {
                    properties += "<w:noWrap/>"
                }
                var padding = cell.padding
                
                if isLabel, width < 3000 {
                    (padding.left, padding.right) = (0, 0)
                }
                properties += "<w:tcMar>\(Self.margins(padding))</w:tcMar>"
                properties += "<w:vAlign w:val=\"\(["top", "center", "bottom"][min(cell.verticalAlign, 2)])\"/>"
                var content = isFirstRow ? cell.paragraphs.flatMap { blocks($0) } : []
                
                if content.last.map({ !$0.hasPrefix("<w:p") }) ?? true {
                    content.append("<w:p/>")
                }
                xml += "<w:tc><w:tcPr>\(properties)</w:tcPr>\(content.joined())</w:tc>"
                column += span
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    private static func areSideBySide(_ tables: [HwpDocument.Table]) -> Bool {
        if tables.allSatisfy({ !$0.layout.inline }) {
            let spans = tables.map { ($0.layout.x, $0.layout.x + $0.layout.width) }.sorted { $0.0 < $1.0 }
            return zip(spans, spans.dropFirst()).allSatisfy { $0.1 <= $1.0 + 100 }
        }
        return tables.allSatisfy(\.layout.inline) && tables.map(\.layout.width).reduce(0, +) < 60000
    }

    /// One borderless row with a cell per table, at Hangul's offsets.
    private mutating func layoutTable(_ tables: [HwpDocument.Table]) -> String {
        let ordered = tables.allSatisfy(\.layout.inline) ? tables : tables.sorted { $0.layout.x < $1.layout.x }
        var columns: [Int] = []
        var cells = ""
        var end = 0
        let outer = floatsTables
        floatsTables = false
        defer {
            floatsTables = outer
        }
        for table in ordered {
            let x = table.layout.inline ? end : table.layout.x
            if x > end {
                columns.append(x - end)
                cells += "<w:tc><w:tcPr><w:tcW w:w=\"\((x - end) / 5)\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
            }
            let width = max(table.layout.width, 1)
            columns.append(width)
            let top = table.layout.inline ? 0 : max(table.layout.y, 0)
            cells += "<w:tc><w:tcPr><w:tcW w:w=\"\(width / 5)\" w:type=\"dxa\"/><w:tcMar><w:top w:w=\"\(top / 5)\" w:type=\"dxa\"/></w:tcMar></w:tcPr>"
                + self.table(table) + "<w:p><w:pPr><w:spacing w:line=\"20\" w:lineRule=\"exact\"/></w:pPr></w:p></w:tc>"
            end = x + width
        }
        let grid = columns.map { "<w:gridCol w:w=\"\(max($0 / 5, 1))\"/>" }.joined()
        return "<w:tbl><w:tblPr><w:tblW w:w=\"\(end / 5)\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/>"
            + "<w:tblCellMar><w:left w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"0\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr>"
            + "<w:tblGrid>\(grid)</w:tblGrid><w:tr>\(cells)</w:tr></w:tbl>"
    }

    private static func margins(_ padding: (left: Int, right: Int, top: Int, bottom: Int)) -> String {
        "<w:top w:w=\"\(padding.top / 5)\" w:type=\"dxa\"/><w:left w:w=\"\(padding.left / 5)\" w:type=\"dxa\"/>"
            + "<w:bottom w:w=\"\(padding.bottom / 5)\" w:type=\"dxa\"/><w:right w:w=\"\(padding.right / 5)\" w:type=\"dxa\"/>"
    }

    private static func border(_ side: String, _ border: HwpDocument.Border) -> String {
        guard let style = border.style else { return "<w:\(side) w:val=\"nil\"/>" }
        let value = switch style {
        case .solid: 
            "single"
        case .dash, .longDash:
            "dashed"
        case .dot, .circle: 
            "dotted"
        case .dashDot: 
            "dotDash"
        case .dashDotDot: 
            "dotDotDash"
        case .double: 
            "double"
        case .thinThick: 
            "thinThickSmallGap"
        case .thickThin: 
            "thickThinSmallGap"
        case .triple: 
            "triple"
        case .wave: 
            "wave"
        }
        let size = min(max(Int((border.width * 72 / 25.4 * 8).rounded()), 4), 96)
        return "<w:\(side) w:val=\"\(value)\" w:sz=\"\(size)\" w:space=\"0\" w:color=\"\(hex(border.color))\"/>"
    }

    // MARK: Drawings
    private mutating func image(_ id: Int) -> (id: String, size: CGSize?)? {
        if let cached = images[id] {
            return cached
        }
        guard let item = document.binData[id], var data = try? item.data() else {
            return nil
        }
        var ext = item.extension == "jpg" ? "jpeg" : item.extension
        
        if !["png", "jpeg", "gif"].contains(ext) {
            guard let png = HwpHTMLWriter.png(from: data) else {
                return nil
            }
            data = png
            ext = "png"
        }
        var size: CGSize?
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            size = CGSize(width: width, height: height)
        }
        let name = "media/image\(id).\(ext)"
        parts.append(("word/\(name)", data))
        let entry = (relate("http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", target: name), size)
        images[id] = entry
        return entry
    }

    private mutating func drawing(_ picture: HwpDocument.Picture) -> String? {
        guard let graphic = pictureGraphic(picture) else {
            return nil
        }
        return place(graphic, layout: picture.layout, uri: "http://schemas.openxmlformats.org/drawingml/2006/picture")
    }

    private mutating func drawing(_ shape: HwpDocument.Shape) -> String {
        if shape.children.isEmpty {
            return place(shapeXML(shape, inGroup: false), layout: shape.layout, uri: "http://schemas.microsoft.com/office/word/2010/wordprocessingShape")
        }
        return place(groupXML(shape, nested: false), layout: shape.layout, uri: "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup")
    }

    /// In line for objects treated as characters, anchored where Hangul placed the rest.
    private mutating func place(_ graphic: String, layout: HwpDocument.ObjectLayout, uri: String) -> String {
        drawingID += 1
        let extent = "<wp:extent cx=\"\(max(layout.width, 1) * 127)\" cy=\"\(max(layout.height, 1) * 127)\"/>"
        let properties = "<wp:docPr id=\"\(drawingID)\" name=\"Object \(drawingID)\"/><wp:cNvGraphicFramePr/>"
            + "<a:graphic><a:graphicData uri=\"\(uri)\">\(graphic)</a:graphicData></a:graphic>"
        if layout.inline {
            return "<w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">\(extent)\(properties)</wp:inline></w:drawing>"
        }
        let horizontal = switch layout.horizontal {
        case .paper: 
            "page"
        case .page: 
            "margin"
        case .column, .paragraph: 
            "column"
        }
        let vertical = switch layout.vertical {
        case .paper: 
            "page"
        case .page, .column: 
            "margin"
        case .paragraph: 
            "paragraph"
        }
        let x = switch layout.horizontalAlign {
        case 1: 
            "<wp:align>center</wp:align>"
        case 2: 
            "<wp:align>right</wp:align>"
        default: 
            "<wp:posOffset>\(layout.x * 127)</wp:posOffset>"
        }
        let y = switch (layout.verticalAlign, layout.vertical) {
        case (1, .paper), (1, .page): 
            "<wp:align>center</wp:align>"
        case (2, .paper), (2, .page): 
            "<wp:align>bottom</wp:align>"
        default: 
            "<wp:posOffset>\(layout.y * 127)</wp:posOffset>"
        }

        let wrap = switch layout.wrap {
        case .square, .tight, .through: 
            layout.width > 20000 ? "<wp:wrapTopAndBottom/>" : "<wp:wrapSquare wrapText=\"bothSides\"/>"
        case .topAndBottom: 
            "<wp:wrapTopAndBottom/>"
        case .behindText, .inFrontOfText:
            "<wp:wrapNone/>"
        }
        let margins = layout.margins
        return "<w:drawing><wp:anchor distT=\"\(margins.top * 127)\" distB=\"\(margins.bottom * 127)\" distL=\"\(margins.left * 127)\" distR=\"\(margins.right * 127)\" "
            + "simplePos=\"0\" relativeHeight=\"\(max(layout.zOrder, 0) * 2 + 2)\" behindDoc=\"\(layout.wrap == .behindText ? 1 : 0)\" locked=\"0\" layoutInCell=\"1\" allowOverlap=\"1\">"
            + "<wp:simplePos x=\"0\" y=\"0\"/><wp:positionH relativeFrom=\"\(horizontal)\">\(x)</wp:positionH>"
            + "<wp:positionV relativeFrom=\"\(vertical)\">\(y)</wp:positionV>\(extent)<wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
            + "\(wrap)\(properties)</wp:anchor></w:drawing>"
    }

    /// A pic:pic, at an offset when inside a group.
    private mutating func pictureGraphic(_ picture: HwpDocument.Picture, offset: (x: Int, y: Int)? = nil) -> String? {
        let (width, height) = (picture.layout.width, picture.layout.height)
        guard let image = image(picture.binID) else { return nil }
        drawingID += 1
        var blip = ""
        switch picture.effect {
        case .none:
            break
        case .grayscale: 
            blip = "<a:grayscl/>"
        case .blackAndWhite: 
            blip = "<a:biLevel thresh=\"50000\"/>"
        }
        var crop = ""
        if let frame = HwpHTMLWriter.cropFrame(picture, pixels: image.size), frame.width > 0, frame.height > 0 {
            let box = (Double(picture.layout.width), Double(picture.layout.height))
            let left = -Double(frame.x) / Double(frame.width)
            let top = -Double(frame.y) / Double(frame.height)
            let right = (Double(frame.x + frame.width) - box.0) / Double(frame.width)
            let bottom = (Double(frame.y + frame.height) - box.1) / Double(frame.height)
            crop = "<a:srcRect l=\"\(Int(left * 100_000))\" t=\"\(Int(top * 100_000))\" r=\"\(Int(right * 100_000))\" b=\"\(Int(bottom * 100_000))\"/>"
        }
        var line = "<a:ln><a:noFill/></a:ln>"
        if picture.border.style != nil {
            line = Self.line(picture.border)
        }
        let position = offset.map { "<a:off x=\"\($0.0 * 127)\" y=\"\($0.1 * 127)\"/>" } ?? "<a:off x=\"0\" y=\"0\"/>"
        let xml = "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(drawingID)\" name=\"Picture \(drawingID)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"\(image.id)\">\(blip)</a:blip>\(crop)<a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm>\(position)<a:ext cx=\"\(max(width, 1) * 127)\" cy=\"\(max(height, 1) * 127)\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>\(line)</pic:spPr></pic:pic>"
        return xml
    }

    private mutating func shapeXML(_ shape: HwpDocument.Shape, inGroup: Bool) -> String {
        drawingID += 1
        let layout = shape.layout
        var transform = "<a:xfrm"
        if shape.kind == .line {
            if shape.start.x > shape.end.x {
                transform += " flipH=\"1\""
            }
            if shape.start.y > shape.end.y {
                transform += " flipV=\"1\""
            }
        }
        let offset = inGroup ? (layout.x * 127, layout.y * 127) : (0, 0)
        transform += "><a:off x=\"\(offset.0)\" y=\"\(offset.1)\"/><a:ext cx=\"\(max(layout.width, 1) * 127)\" cy=\"\(max(layout.height, 1) * 127)\"/></a:xfrm>"
        let geometry = switch shape.kind {
        case .line: 
            "<a:prstGeom prst=\"line\"><a:avLst/></a:prstGeom>"
        case .ellipse: 
            "<a:prstGeom prst=\"ellipse\"><a:avLst/></a:prstGeom>"
        case .rectangle where shape.cornerRatio > 0:
            "<a:prstGeom prst=\"roundRect\"><a:avLst><a:gd name=\"adj\" fmla=\"val \(min(shape.cornerRatio, 50) * 1000)\"/></a:avLst></a:prstGeom>"
        case .rectangle, .other: 
            "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
        }
        var fill = "<a:noFill/>"
        if let image = shape.image, let entry = self.image(image.binID) {
            let effect = image.effect == .grayscale ? "<a:grayscl/>" : image.effect == .blackAndWhite ? "<a:biLevel thresh=\"50000\"/>" : ""
            let mode = image.mode == .tile ? "<a:tile tx=\"0\" ty=\"0\" sx=\"100000\" sy=\"100000\" flip=\"none\" algn=\"tl\"/>" : "<a:stretch><a:fillRect/></a:stretch>"
            fill = "<a:blipFill><a:blip r:embed=\"\(entry.id)\">\(effect)</a:blip>\(mode)</a:blipFill>"
        } else if let color = shape.fill {
            fill = "<a:solidFill><a:srgbClr val=\"\(Self.hex(color))\"/></a:solidFill>"
        }
        let line = shape.line.style == nil ? "<a:ln><a:noFill/></a:ln>" : Self.line(shape.line)
        var xml = "<wps:wsp>"
        if inGroup {
            xml += "<wps:cNvPr id=\"\(drawingID)\" name=\"Shape \(drawingID)\"/>"
        }
        xml += shape.text.isEmpty ? "<wps:cNvSpPr/>" : "<wps:cNvSpPr txBox=\"1\"/>"
        xml += "<wps:spPr>\(transform)\(geometry)\(shape.kind == .line ? "<a:noFill/>" : fill)\(line)</wps:spPr>"
        if !shape.text.isEmpty {
            let outer = floatsTables
            floatsTables = false
            let content = shape.text.flatMap { blocks($0) }
            floatsTables = outer
            xml += "<wps:txbx><w:txbxContent>\(content.isEmpty ? "<w:p/>" : content.joined())</w:txbxContent></wps:txbx>"
        }
        let padding = shape.textPadding
        let anchor = ["t", "ctr", "b"][min(shape.textVerticalAlign, 2)]
        xml += "<wps:bodyPr rot=\"0\" vert=\"horz\" wrap=\"square\" lIns=\"\(padding.left * 127)\" tIns=\"\(padding.top * 127)\" rIns=\"\(padding.right * 127)\" bIns=\"\(padding.bottom * 127)\" anchor=\"\(anchor)\"><a:noAutofit/></wps:bodyPr>"
        return xml + "</wps:wsp>"
    }

    /// Hangul's group: its children are placed relative to its corner, as Word's are to chOff.
    private mutating func groupXML(_ group: HwpDocument.Shape, nested: Bool) -> String {
        let layout = group.layout
        let size = "<a:ext cx=\"\(max(layout.width, 1) * 127)\" cy=\"\(max(layout.height, 1) * 127)\"/>"
        let offset = nested ? "<a:off x=\"\(layout.x * 127)\" y=\"\(layout.y * 127)\"/>" : "<a:off x=\"0\" y=\"0\"/>"
        let transform = "<a:xfrm>\(offset)\(size)<a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"\(max(layout.width, 1) * 127)\" cy=\"\(max(layout.height, 1) * 127)\"/></a:xfrm>"
        var xml: String
        if nested {
            drawingID += 1
            xml = "<wpg:grpSp><wpg:cNvPr id=\"\(drawingID)\" name=\"Group \(drawingID)\"/><wpg:cNvGrpSpPr/><wpg:grpSpPr>\(transform)</wpg:grpSpPr>"
        } else {
            xml = "<wpg:wgp><wpg:cNvGrpSpPr/><wpg:grpSpPr>\(transform)</wpg:grpSpPr>"
        }
        for child in group.children {
            switch child {
            case .picture(let picture):
                xml += pictureGraphic(picture, offset: (picture.layout.x, picture.layout.y)) ?? ""
            case .shape(let shape):
                xml += shape.children.isEmpty ? shapeXML(shape, inGroup: true) : groupXML(shape, nested: true)
            default:
                break
            }
        }
        return xml + (nested ? "</wpg:grpSp>" : "</wpg:wgp>")
    }

    private static func line(_ border: HwpDocument.Border) -> String {
        let width = Int(max(border.width, 0.1) * 36000)
        let dash = switch border.style {
        case .dash, .longDash: 
            "<a:prstDash val=\"dash\"/>"
        case .dot, .circle: 
            "<a:prstDash val=\"sysDot\"/>"
        case .dashDot: 
            "<a:prstDash val=\"dashDot\"/>"
        case .dashDotDot: 
            "<a:prstDash val=\"sysDashDotDot\"/>"
        default: 
            ""
        }
        return "<a:ln w=\"\(width)\"><a:solidFill><a:srgbClr val=\"\(hex(border.color))\"/></a:solidFill>\(dash)</a:ln>"
    }

    // MARK: Text
    static func hex(_ color: HwpDocument.Color) -> String {
        String(format: "%02X%02X%02X", color.red, color.green, color.blue)
    }

    /// XML text, without the control characters XML forbids.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": 
                result += "&amp;"
            case "<": 
                result += "&lt;"
            case ">": 
                result += "&gt;"
            case "\"": 
                result += "&quot;"
            case "\t", "\n", "\r":
                result.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || (0xFFFE...0xFFFF).contains(scalar.value):
                break
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
