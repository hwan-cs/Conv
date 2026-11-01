import Foundation

/// Walks document.xml and writes HTML whose CSS mirrors Word's layout model:
/// paragraph spacing adds up instead of collapsing, list labels are text, tables use the grid.
struct DocxHTMLWriter {
    struct Output {
        var html: String
        var page: PagedPDFRenderer.PageSetup
        var headerFooter: DocxHeaderFooter
    }

    private static let markupCompatibility = "http://schemas.openxmlformats.org/markup-compatibility/2006"

    private let package: DocxPackage
    private let styles: DocxStyles
    private let theme: DocxTheme
    private let fonts: DocxEmbeddedFonts
    private let page: PagedPDFRenderer.PageSetup
    /// The section being written; floating objects are placed against its column.
    private var section: PagedPDFRenderer.PageSetup
    /// Width of one of the section's text columns.
    private var columnWidth = 0.0
    private var numbering: DocxNumbering
    private var html = ""
    /// Formatting from the enclosing table's style, applied to paragraphs in its cells.
    private var tableCellFormat: (paragraph: ParagraphFormat, run: RunFormat)?
    /// Left indent of the paragraph being written; floating objects are placed against the column, not the indent.
    private var paragraphIndent = 0.0
    /// The part being written's relationships: the main document's, or a header's.
    private var relationships: [String: String]
    /// In headers and footers, PAGE and NUMPAGES fields become tokens filled in per page.
    private var substitutesPageFields = false
    /// Line spacing of the paragraph being written. Word sizes each line from the text on it,
    /// so line height goes on runs rather than on the paragraph.
    private var lineSpacing: ParagraphFormat.LineSpacing?
    /// Stands for a tab in a paragraph's HTML until the paragraph knows its tab stops.
    private static let tabMarker: Character = "\u{E002}"
    /// Absolute tabs (`w:ptab`) align to the margin rather than to the next stop.
    private static let absoluteTabMarkers: [Character: String] = ["\u{E003}": "left", "\u{E004}": "center", "\u{E005}": "right"]
    private var field = FieldState()

    /// A complex field: `fldChar begin`, `instrText`, `fldChar separate`, cached result runs, `fldChar end`.
    private struct FieldState {
        enum Phase { case none, instruction, result }
        var phase = Phase.none
        var instruction = ""
        var token: String?
    }

    static func convert(_ url: URL) throws -> Output {
        let package = try DocxPackage(url: url)
        guard let body = try package.xml(at: package.documentPath)?.child("body") else {
            throw DocxPackage.PackageError.notADocx
        }
        let sections = sections(of: body)
        // One print setup serves every section: take the widest column and pad the narrower ones.
        var page = pageSetup(body.child("sectPr"))
        page.margins.left = sections.map { pageSetup($0.properties).margins.left }.min() ?? page.margins.left
        page.margins.right = sections.map { pageSetup($0.properties).margins.right }.min() ?? page.margins.right

        var writer = DocxHTMLWriter(
            package: package,
            styles: DocxStyles(try package.partPath(ofType: "styles").flatMap(package.xml)),
            theme: DocxTheme(try package.partPath(ofType: "theme").flatMap(package.xml)),
            fonts: DocxEmbeddedFonts(package: package),
            page: page,
            numbering: DocxNumbering(try package.partPath(ofType: "numbering").flatMap(package.xml))
        )
        for (index, section) in sections.enumerated() {
            writer.section = pageSetup(section.properties)
            let columns = Self.columns(section.properties)
            let textWidth = writer.section.paperSize.width - writer.section.margins.left - writer.section.margins.right
            writer.columnWidth = (textWidth - columns.gap * Double(columns.count - 1)) / Double(columns.count)
            var css = [
                "padding-left:\(decimal(writer.section.margins.left - page.margins.left))pt",
                "padding-right:\(decimal(writer.section.margins.right - page.margins.right))pt",
            ]
            var attributes = ""
            if columns.count > 1 {
                // WebKit prints CSS columns as one; `columnScript` lays them out before printing.
                let height = writer.section.paperSize.height - writer.section.margins.top - writer.section.margins.bottom
                attributes = #" data-columns="\#(columns.count)" data-gap="\#(decimal(columns.gap))""#
                    + #" data-width="\#(decimal(writer.columnWidth))" data-height="\#(decimal(height))""#
                    + (columns.separator ? #" data-separator="1""# : "")
            }
            if index > 0 && section.properties?.child("type")?.value() != "continuous" {
                css.append("break-before:page")
            }
            writer.html += #"<div class="section"\#(attributes) style="\#(css.joined(separator: ";"))">"# + "\n"
            writer.blocks(section.elements)
            writer.html += "</div>\n"
        }
        let settings = try package.partPath(ofType: "settings").flatMap(package.xml)
        let headerFooter = DocxHeaderFooter(
            sections: writer.headerFooterSections(sections),
            evenAndOddHeaders: settings?.child("evenAndOddHeaders")?.isOn == true,
            page: page,
            fontFaces: writer.fonts.css
        )
        return Output(html: document(writer.html, fontFaces: writer.fonts.css), page: page, headerFooter: headerFooter)
    }

    /// Each section's headers and footers as HTML. Word inherits a missing reference from the previous section.
    private mutating func headerFooterSections(_ sections: [Section]) -> [DocxHeaderFooter.Section] {
        // Part paths by type; an inherited part is laid out again in the inheriting section's column.
        var headerPaths: [String: String] = [:]
        var footerPaths: [String: String] = [:]
        var result: [DocxHeaderFooter.Section] = []
        for section in sections {
            let properties = section.properties
            self.section = Self.pageSetup(properties)
            columnWidth = self.section.paperSize.width - self.section.margins.left - self.section.margins.right
            headerPaths.merge(referencedPaths("headerReference", in: properties)) { $1 }
            footerPaths.merge(referencedPaths("footerReference", in: properties)) { $1 }
            let headers = headerPaths.mapValues { part(at: $0) }
            let footers = footerPaths.mapValues { part(at: $0) }
            let margins = properties?.child("pgMar")
            result.append(DocxHeaderFooter.Section(
                page: self.section,
                headerDistance: twips(margins?.number("header") ?? 720),
                footerDistance: twips(margins?.number("footer") ?? 720),
                startsNewPage: properties?.child("type")?.value() != "continuous",
                firstText: Self.firstText(section.elements),
                hasTitlePage: properties?.child("titlePg")?.isOn == true,
                pageNumberStart: properties?.child("pgNumType")?.number("start").map(Int.init),
                headers: headers,
                footers: footers
            ))
        }
        return result
    }

    /// A section's own header or footer part paths by type ("default", "first", "even").
    private func referencedPaths(_ name: String, in properties: XMLElement?) -> [String: String] {
        var result: [String: String] = [:]
        for reference in properties?.children(name) ?? [] {
            guard let id = reference.value("id", in: OOXMLNamespace.r), let path = package.relationships[id] else { continue }
            result[reference.value("type") ?? "default"] = path
        }
        return result
    }

    /// A header or footer part, written with its own relationships and with live page fields.
    private mutating func part(at path: String) -> String {
        guard let root = try? package.xml(at: path) else { return "" }
        let savedRelationships = relationships
        relationships = (try? package.relationships(forPart: path)) ?? [:]
        substitutesPageFields = true
        defer {
            relationships = savedRelationships
            substitutesPageFields = false
        }
        return rendering { $0.blocks(root.elements) }
    }

    /// Enough leading text to find the section in the rendered PDF.
    private static func firstText(_ elements: [XMLElement]) -> String? {
        var text = ""
        func collect(_ element: XMLElement) {
            guard text.count < 12 else { return }
            if element.localName == "t" {
                text += (element.stringValue ?? "").replacingOccurrences(of: DocxPackage.blankTextMarker, with: "")
            }
            element.elements.forEach(collect)
        }
        elements.forEach(collect)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(12))
    }

    private struct Section {
        var elements: [XMLElement]
        var properties: XMLElement?
    }

    /// A section's text columns (`w:cols`): how many, the gap between them, and whether a line
    /// separates them. Columns of unequal widths are drawn equal.
    private static func columns(_ sectPr: XMLElement?) -> (count: Int, gap: Double, separator: Bool) {
        guard let cols = sectPr?.child("cols") else { return (1, 0, false) }
        let count = max(Int(cols.number("num") ?? Double(cols.children("col").count)), 1)
        return (count, twips(cols.number("space") ?? 720), cols.value("sep").map { $0 == "1" || $0 == "true" } ?? false)
    }

    /// Every section but the last ends with a paragraph whose pPr holds its sectPr; the last one's is the body's.
    private static func sections(of body: XMLElement) -> [Section] {
        var result: [Section] = []
        var current: [XMLElement] = []
        for element in body.elements {
            if element.localName == "sectPr" {
                result.append(Section(elements: current, properties: element))
                current = []
                continue
            }
            current.append(element)
            if element.localName == "p", let properties = element.child("pPr")?.child("sectPr") {
                result.append(Section(elements: current, properties: properties))
                current = []
            }
        }
        if !current.isEmpty {
            result.append(Section(elements: current, properties: nil))
        }
        return result
    }

    private init(
        package: DocxPackage,
        styles: DocxStyles,
        theme: DocxTheme,
        fonts: DocxEmbeddedFonts,
        page: PagedPDFRenderer.PageSetup,
        numbering: DocxNumbering
    ) {
        self.package = package
        self.styles = styles
        self.theme = theme
        self.fonts = fonts
        self.page = page
        self.section = page
        self.columnWidth = page.paperSize.width - page.margins.left - page.margins.right
        self.numbering = numbering
        self.relationships = package.relationships
    }

    // MARK: - Blocks

    private mutating func blocks(_ elements: [XMLElement]) {
        let siblings = elements.filter { $0.uri == OOXMLNamespace.w }
        for (index, element) in siblings.enumerated() {
            switch element.localName {
            case "p":
                paragraph(
                    element,
                    previousStyle: index > 0 ? Self.paragraphStyle(siblings[index - 1]) : nil,
                    nextStyle: index + 1 < siblings.count ? Self.paragraphStyle(siblings[index + 1]) : nil
                )
            case "tbl": table(element)
            case "sdt", "customXml": blocks(element.child("sdtContent")?.elements ?? element.elements)
            default: break
            }
        }
    }

    /// No text or picture, e.g. a code listing's blank line that holds only a tab. Its height comes
    /// from the paragraph mark, which runs can't provide.
    private static func isBlank(_ html: String) -> Bool {
        guard !html.contains("<img") else { return false }
        let text = html.replacing(/<[^>]*>/, with: "")
        return text.allSatisfy { $0.isWhitespace || $0 == "\u{200B}" || isTabMarker($0) }
    }

    private static func isTabMarker(_ character: Character) -> Bool {
        character == tabMarker || absoluteTabMarkers[character] != nil
    }

    /// A paragraph's style id, or "" for the default style; nil for non-paragraphs.
    private static func paragraphStyle(_ element: XMLElement) -> String? {
        guard element.localName == "p" else { return nil }
        return element.child("pPr")?.child("pStyle")?.value() ?? ""
    }

    private mutating func paragraph(_ p: XMLElement, previousStyle: String?, nextStyle: String?) {
        let pPr = p.child("pPr")
        let styleID = pPr?.child("pStyle")?.value()
        let style = styles.paragraph(styleID: styleID, table: tableCellFormat)
        let direct = ParagraphFormat(pPr)
        var format = style.paragraph.overlaid(by: direct)
        var label: String?
        var labelRun = RunFormat()
        if let reference = format.numbering, let level = numbering.level(reference) {
            // A list level's indent sits between the paragraph style and direct formatting.
            format = style.paragraph.overlaid(by: level.paragraph).overlaid(by: direct)
            label = numbering.nextLabel(reference)
            labelRun = level.run
        }
        if format.contextualSpacing == true {
            if previousStyle == (styleID ?? "") { format.spaceBefore = 0 }
            if nextStyle == (styleID ?? "") { format.spaceAfter = 0 }
        }
        let markRun = style.run.overlaid(by: RunFormat(pPr?.child("rPr")))
        paragraphIndent = format.indentLeft ?? 0
        lineSpacing = format.lineSpacing

        // A page break inside a paragraph splits it; the rest starts the next page.
        var chunks = [""]
        inlines(p.elements, base: style.run, into: &chunks)
        var breaksBeforeFirst = format.pageBreakBefore == true
        // A paragraph that is only a page break should not leave an empty line behind on the old page.
        if chunks.count > 1 && chunks[0].isEmpty && label == nil {
            chunks.removeFirst()
            breaksBeforeFirst = true
        }

        for (index, chunk) in chunks.enumerated() {
            var css = paragraphCSS(format, run: markRun, isEmpty: Self.isBlank(chunk) && (index > 0 || label == nil))
            if index > 0 || breaksBeforeFirst {
                css.append("break-before:page")
            }
            var content = placingTabs(chunk, format: format, markRun: markRun)
            if index == 0, let label {
                let hanging = max(-(format.firstLine ?? 0), 0)
                let width = hanging > 0 ? "min-width:\(decimal(hanging))pt;" : "padding-right:0.5em;"
                let labelCSS = runCSS(markRun.overlaid(by: labelRun)).joined(separator: ";")
                content = #"<span class="label" style="\#(width)\#(labelCSS)">\#(Self.escape(label))</span>"# + content
            }
            // A div rather than <p>: a text box's paragraphs sit inside this one, and HTML would
            // close a <p> at the first nested one.
            html += #"<div class="p" style="\#(css.joined(separator: ";"))">\#(content.isEmpty ? "<br>" : content)</div>"# + "\n"
        }
    }

    // MARK: - Inlines

    private mutating func inlines(_ elements: [XMLElement], base: RunFormat, into chunks: inout [String]) {
        for element in elements {
            if element.uri == Self.markupCompatibility, element.localName == "AlternateContent" {
                let choice = element.elements.first { $0.localName == "Choice" } ?? element.elements.first
                inlines(choice?.elements ?? [], base: base, into: &chunks)
                continue
            }
            guard element.uri == OOXMLNamespace.w else { continue }
            switch element.localName {
            case "r": run(element, base: base, into: &chunks)
            case "fldSimple" where substitutesPageFields && Self.pageFieldToken(element.value("instr")) != nil:
                chunks[chunks.count - 1] += Self.pageFieldToken(element.value("instr"))!
            case "hyperlink", "ins", "smartTag", "fldSimple", "customXml", "moveTo", "dir", "bdo":
                inlines(element.elements, base: base, into: &chunks)
            case "sdt": inlines(element.child("sdtContent")?.elements ?? [], base: base, into: &chunks)
            default: break
            }
        }
    }

    private mutating func run(_ r: XMLElement, base: RunFormat, into chunks: inout [String]) {
        let rPr = r.child("rPr")
        let format = base
            .overlaid(by: styles.run(styleID: rPr?.child("rStyle")?.value()))
            .overlaid(by: RunFormat(rPr))
        var text = ""
        func flush() {
            guard !text.isEmpty else { return }
            chunks[chunks.count - 1] += #"<span style="\#(runCSS(format).joined(separator: ";"))">\#(text)</span>"#
            text = ""
        }

        for element in r.elements {
            if element.uri == Self.markupCompatibility, element.localName == "AlternateContent" {
                flush()
                let choice = element.elements.first { $0.localName == "Choice" } ?? element.elements.first
                for child in choice?.elements ?? [] where child.localName == "drawing" {
                    chunks[chunks.count - 1] += drawing(child)
                }
                continue
            }
            guard element.uri == OOXMLNamespace.w else { continue }
            if substitutesPageFields, handleField(element, into: &text) { continue }
            switch element.localName {
            case "t":
                let value = (element.stringValue ?? "").replacingOccurrences(of: DocxPackage.blankTextMarker, with: "")
                text += Self.escape(value)
            case "tab":
                flush()
                chunks[chunks.count - 1].append(Self.tabMarker)
            case "ptab":
                flush()
                let alignment = element.value("alignment") ?? "left"
                let marker = Self.absoluteTabMarkers.first { $0.value == alignment }?.key ?? Self.tabMarker
                chunks[chunks.count - 1].append(marker)
            case "br":
                if element.value("type") == "page" {
                    flush()
                    chunks.append("")
                } else if element.value("type") == "column" {
                    text += #"<span data-column-break="1"></span>"#
                } else {
                    text += "<br>"
                }
            case "cr": text += "<br>"
            case "noBreakHyphen": text += "&#8209;"
            case "softHyphen": text += "&shy;"
            case "sym":
                if let code = element.value("char").flatMap({ UInt32($0, radix: 16) }) {
                    text += Self.escape(Self.symbol(code))
                }
            case "drawing":
                flush()
                chunks[chunks.count - 1] += drawing(element)
            case "pict":
                flush()
                chunks[chunks.count - 1] += vmlImage(element)
            default: break
            }
        }
        flush()
    }

    /// Tracks complex fields in headers and footers; returns true when the element was consumed.
    /// A PAGE or NUMPAGES field's cached result is replaced with a token filled in per page.
    private mutating func handleField(_ element: XMLElement, into text: inout String) -> Bool {
        switch element.localName {
        case "fldChar":
            switch element.value("fldCharType") {
            case "begin":
                field = FieldState(phase: .instruction)
            case "separate":
                field.phase = .result
                field.token = Self.pageFieldToken(field.instruction)
                if let token = field.token { text += token }
            case "end":
                if field.phase == .instruction, let token = Self.pageFieldToken(field.instruction) {
                    text += token
                }
                field = FieldState()
            default: break
            }
            return true
        case "instrText":
            if field.phase == .instruction { field.instruction += element.stringValue ?? "" }
            return true
        default:
            // Skip the stale cached page number.
            return field.phase == .result && field.token != nil
        }
    }

    private static func pageFieldToken(_ instruction: String?) -> String? {
        switch instruction?.split(separator: " ").first?.uppercased() {
        case "PAGE": DocxHeaderFooter.pageToken
        case "NUMPAGES", "SECTIONPAGES": DocxHeaderFooter.pageCountToken
        default: nil
        }
    }

    /// With custom tab stops, the text after the n-th tab is placed at the n-th stop, aligned by its kind.
    /// That matches Word whenever earlier text ends before the next stop, as in headers, footers and
    /// "label → value" lines. Without stops, a tab is a 36pt gap.
    ///
    /// Each segment gets a box that stays inside the column: anything wider widens the document,
    /// and WebKit then shrinks every page. Stops past the right margin sit on it, as in Word.
    private func placingTabs(_ html: String, format: ParagraphFormat, markRun: RunFormat) -> String {
        guard html.contains(where: Self.isTabMarker) else { return html }
        let stops = (format.tabs ?? []).filter { !["clear", "bar"].contains($0.kind) }
        // Segment n follows tab n; `absolutes` holds the alignment of absolute tabs.
        var segments = [""]
        var absolutes: [String?] = [nil]
        for character in html {
            if Self.isTabMarker(character) {
                segments.append("")
                absolutes.append(Self.absoluteTabMarkers[character])
            } else {
                segments[segments.count - 1].append(character)
            }
        }
        guard !stops.isEmpty || absolutes.contains(where: { $0 != nil }) else {
            return segments.joined(separator: #"<span class="tab"></span>"#)
        }
        let available = max(section.paperSize.width - section.margins.left - section.margins.right
            - (format.indentLeft ?? 0) - (format.indentRight ?? 0), 0)
        // Positioned segments leave the flow; this keeps the line's height.
        let strut = #"<span style="\#(runCSS(markRun).joined(separator: ";"))">&#8203;</span>"#
        var result = strut + segments[0]
        var stopIndex = 0
        for (segment, absolute) in zip(segments, absolutes).dropFirst() {
            let stop: ParagraphFormat.TabStop
            if let absolute {
                let position: Double = switch absolute {
                case "center": available / 2
                case "right": available
                default: 0
                }
                stop = ParagraphFormat.TabStop(kind: absolute, position: position + (format.indentLeft ?? 0))
            } else if stopIndex < stops.count {
                stop = stops[stopIndex]
                stopIndex += 1
            } else {
                result += #"<span class="tab"></span>"# + segment
                continue
            }
            let position = min(max(stop.position - (format.indentLeft ?? 0), 0), available)
            let (left, width, align) = switch stop.kind {
            case "center":
                (position - min(position, available - position), 2 * min(position, available - position), "center")
            case "right", "end", "decimal":
                (0, position, "right")
            default:
                (position, available - position, "left")
            }
            let box = "position:absolute;left:\(decimal(left))pt;width:\(decimal(width))pt;text-align:\(align);text-indent:0;white-space:nowrap"
            result += #"<span style="\#(box)">\#(segment)</span>"#
        }
        return result
    }

    // MARK: - Drawings

    /// Inline and floating pictures and shapes. Floating ones are placed against their paragraph,
    /// which is how Word positions most of them (`relativeFrom="paragraph"`/`"column"`).
    private mutating func drawing(_ drawing: XMLElement) -> String {
        guard let container = drawing.child("inline", in: OOXMLNamespace.wp) ?? drawing.child("anchor", in: OOXMLNamespace.wp) else {
            return ""
        }
        let extent = container.child("extent", in: OOXMLNamespace.wp)
        // EMU: 914400 per inch, 12700 per point.
        let width = Self.emu(extent, "cx") ?? 0
        let height = Self.emu(extent, "cy") ?? 0
        let graphic = container.firstDescendant("graphicData", in: OOXMLNamespace.a)

        let isPicture = graphic?.child("pic", in: OOXMLNamespace.pic) != nil
        if container.localName == "inline", isPicture {
            guard let fill = graphic?.firstDescendant("blipFill", in: OOXMLNamespace.pic) else { return "" }
            if let cropped = croppedPicture(fill, css: ["display:inline-block", "vertical-align:bottom", "width:\(decimal(width))pt", "height:\(decimal(height))pt"]) {
                return cropped
            }
            guard let id = fill.child("blip", in: OOXMLNamespace.a)?.value("embed", in: OOXMLNamespace.r) else { return "" }
            return imageTag(relationship: id, css: ["width:\(decimal(width))pt", "max-width:100%", "height:auto"])
        }

        let content: String
        if let shape = graphic?.child("wsp", in: OOXMLNamespace.wps) {
            content = self.shape(shape, isLine: height < 1)
        } else if let group = graphic?.child("wgp", in: OOXMLNamespace.wpg) {
            content = self.group(group, width: width, height: height)
        } else if let fill = graphic?.firstDescendant("blipFill", in: OOXMLNamespace.pic) {
            content = picture(fill)
        } else {
            return ""
        }
        let size = ["width:\(decimal(width))pt", "height:\(decimal(height))pt"]
        if container.localName == "inline" {
            // A text box or group in the line, as big as Word draws it.
            let box = ["display:inline-block", "position:relative", "vertical-align:bottom", "text-indent:0"] + size
            return #"<span style="\#(box.joined(separator: ";"))">\#(content)</span>"#
        }
        let box = ["display:block"] + size + anchorCSS(container, width: width)
        return #"<span style="\#(box.joined(separator: ";"))">\#(content)</span>"#
    }

    /// A group's shapes, pictures and inner groups, each placed in the group's own coordinates
    /// (`chOff`, `chExt`) scaled to the size it is drawn at.
    private mutating func group(_ group: XMLElement, width: Double, height: Double) -> String {
        let properties = group.child("grpSpPr", in: OOXMLNamespace.wpg)?.child("xfrm", in: OOXMLNamespace.a)
        let origin = Self.point(properties?.child("chOff", in: OOXMLNamespace.a), "x", "y")
        let extent = Self.point(properties?.child("chExt", in: OOXMLNamespace.a), "cx", "cy")
        let scaleX = extent.x > 0 ? width / extent.x : 1
        let scaleY = extent.y > 0 ? height / extent.y : 1
        var children = ""
        for child in group.elements {
            let xfrm: XMLElement?
            switch child.localName {
            case "wsp": xfrm = child.child("spPr", in: OOXMLNamespace.wps)?.child("xfrm", in: OOXMLNamespace.a)
            case "pic": xfrm = child.child("spPr", in: OOXMLNamespace.pic)?.child("xfrm", in: OOXMLNamespace.a)
            case "grpSp": xfrm = child.child("grpSpPr", in: OOXMLNamespace.wpg)?.child("xfrm", in: OOXMLNamespace.a)
            default: continue
            }
            let offset = Self.point(xfrm?.child("off", in: OOXMLNamespace.a), "x", "y")
            let size = Self.point(xfrm?.child("ext", in: OOXMLNamespace.a), "cx", "cy")
            let (childWidth, childHeight) = (size.x * scaleX, size.y * scaleY)
            let content: String
            switch child.localName {
            case "wsp": content = shape(child, isLine: childHeight < 1)
            case "grpSp": content = self.group(child, width: childWidth, height: childHeight)
            default:
                guard let fill = child.child("blipFill", in: OOXMLNamespace.pic) else { continue }
                content = picture(fill)
            }
            let css = [
                "position:absolute", "display:block",
                "left:\(decimal((offset.x - origin.x) * scaleX))pt", "top:\(decimal((offset.y - origin.y) * scaleY))pt",
                "width:\(decimal(childWidth))pt", "height:\(decimal(childHeight))pt",
            ]
            children += #"<span style="\#(css.joined(separator: ";"))">\#(content)</span>"#
        }
        return #"<span style="display:block;position:relative;width:100%;height:100%">\#(children)</span>"#
    }

    /// A picture filling its box, cropped as `a:srcRect` says.
    private func picture(_ blipFill: XMLElement) -> String {
        if let cropped = croppedPicture(blipFill, css: ["display:block", "width:100%", "height:100%"]) { return cropped }
        guard let id = blipFill.child("blip", in: OOXMLNamespace.a)?.value("embed", in: OOXMLNamespace.r) else { return "" }
        return imageTag(relationship: id, css: ["display:block", "width:100%", "height:100%"])
    }

    /// The part of the image `a:srcRect` keeps, in a box of `css` that hides the rest: the image is
    /// enlarged so the kept part fills the box. Nil when nothing is cropped.
    private func croppedPicture(_ blipFill: XMLElement, css: [String]) -> String? {
        guard let id = blipFill.child("blip", in: OOXMLNamespace.a)?.value("embed", in: OOXMLNamespace.r),
              let crop = blipFill.child("srcRect", in: OOXMLNamespace.a) else { return nil }
        // Thousandths of a percent of the image, from each edge.
        let edge = { (name: String) in (crop.attribute(forName: name)?.stringValue).flatMap(Double.init).map { $0 / 100_000 } ?? 0 }
        let (left, top, right, bottom) = (edge("l"), edge("t"), edge("r"), edge("b"))
        let keptWidth = 1 - left - right
        let keptHeight = 1 - top - bottom
        guard keptWidth > 0, keptHeight > 0, left != 0 || top != 0 || right != 0 || bottom != 0 else { return nil }
        let image = imageTag(relationship: id, css: [
            "position:absolute", "max-width:none",
            "width:\(decimal(100 / keptWidth))%", "height:\(decimal(100 / keptHeight))%",
            "left:\(decimal(-100 * left / keptWidth))%", "top:\(decimal(-100 * top / keptHeight))%",
        ])
        let box = css + ["position:relative", "overflow:hidden"]
        return #"<span style="\#(box.joined(separator: ";"))">\#(image)</span>"#
    }

    /// Two EMU attributes as points.
    private static func point(_ element: XMLElement?, _ x: String, _ y: String) -> CGPoint {
        CGPoint(x: emu(element, x) ?? 0, y: emu(element, y) ?? 0)
    }

    private func anchorCSS(_ anchor: XMLElement, width: Double) -> [String] {
        let horizontal = anchor.child("positionH", in: OOXMLNamespace.wp)
        var left: Double
        switch horizontal?.child("align", in: OOXMLNamespace.wp)?.stringValue {
        case "center": left = (columnWidth - width) / 2
        case "right", "outside": left = columnWidth - width
        case "left", "inside": left = 0
        default: left = Self.emu(horizontal?.child("posOffset", in: OOXMLNamespace.wp)?.stringValue) ?? 0
        }
        if horizontal?.attribute(forName: "relativeFrom")?.stringValue == "page" {
            left -= section.margins.left
        }
        left -= paragraphIndent
        let vertical = anchor.child("positionV", in: OOXMLNamespace.wp)
        let top = Self.emu(vertical?.child("posOffset", in: OOXMLNamespace.wp)?.stringValue) ?? 0

        let wrap = anchor.elements.first { $0.localName?.hasPrefix("wrap") == true }?.localName ?? "wrapNone"
        switch wrap {
        case "wrapTopAndBottom":
            return ["margin-left:\(decimal(max(left, 0)))pt"]
        case "wrapSquare", "wrapTight", "wrapThrough":
            let side = left + width / 2 > columnWidth / 2 ? "right" : "left"
            return ["float:\(side)", "margin:0 9pt"]
        default:
            let behind = anchor.attribute(forName: "behindDoc")?.stringValue == "1"
            return ["position:absolute", "left:\(decimal(left))pt", "top:\(decimal(top))pt", "z-index:\(behind ? -1 : 1)"]
        }
    }

    /// Word 2010 shapes: lines, filled rectangles, and text boxes.
    private mutating func shape(_ wsp: XMLElement, isLine: Bool) -> String {
        let properties = wsp.child("spPr", in: OOXMLNamespace.wps)
        let style = wsp.child("style", in: OOXMLNamespace.wps)
        let geometry = properties?.child("prstGeom", in: OOXMLNamespace.a)?.attribute(forName: "prst")?.stringValue ?? "rect"
        let outline = properties?.child("ln", in: OOXMLNamespace.a)
        let outlineWidth = Self.emu(outline, "w") ?? 0.75
        let outlineColor: String? = outline?.child("noFill", in: OOXMLNamespace.a) != nil ? nil
            : color(outline?.child("solidFill", in: OOXMLNamespace.a)) ?? color(style?.child("lnRef", in: OOXMLNamespace.a))
        let fill: String? = properties?.child("noFill", in: OOXMLNamespace.a) != nil ? nil
            : color(properties?.child("solidFill", in: OOXMLNamespace.a)) ?? color(style?.child("fillRef", in: OOXMLNamespace.a))

        if isLine || geometry == "line" || geometry.hasPrefix("straightConnector") {
            return #"<span style="display:block;border-top:\#(decimal(outlineWidth))pt solid \#(outlineColor ?? "#000000")"></span>"#
        }
        var css = ["display:block", "width:100%", "height:100%", "box-sizing:border-box"]
        if let fill { css.append("background:\(fill)") }
        // A picture filling the shape: stretched over it, or tiled at its own size.
        if let blipFill = properties?.child("blipFill", in: OOXMLNamespace.a),
           let id = blipFill.child("blip", in: OOXMLNamespace.a)?.value("embed", in: OOXMLNamespace.r),
           let uri = dataURI(relationship: id) {
            let isTiled = blipFill.child("tile", in: OOXMLNamespace.a) != nil
            css += ["background-image:url(\(uri))", isTiled ? "background-repeat:repeat" : "background-size:100% 100%"]
        }
        if let outlineColor { css.append("border:\(decimal(outlineWidth))pt solid \(outlineColor)") }
        if geometry == "roundRect" { css.append("border-radius:10%") }
        if geometry == "ellipse" { css.append("border-radius:50%") }
        var text = ""
        if let content = wsp.child("txbx", in: OOXMLNamespace.wps)?.child("txbxContent") {
            // Insets default to 0.1 inch at the sides and 0.05 inch above and below.
            let body = wsp.child("bodyPr", in: OOXMLNamespace.wps)
            let insets = [("tIns", 3.6), ("rIns", 7.2), ("bIns", 3.6), ("lIns", 7.2)].map { Self.emu(body, $0.0) ?? $0.1 }
            css.append("padding:" + insets.map { "\(decimal($0))pt" }.joined(separator: " "))
            css += ["text-indent:0", "overflow:hidden"]
            switch body?.attribute(forName: "anchor")?.stringValue {
            case "ctr": css += ["display:flex", "flex-direction:column", "justify-content:center"]
            case "b": css += ["display:flex", "flex-direction:column", "justify-content:flex-end"]
            default: break
            }
            text = rendering { $0.blocks(content.elements) }
        }
        return #"<span style="\#(css.joined(separator: ";"))">\#(text)</span>"#
    }

    /// `a:srgbClr` or a theme `a:schemeClr` inside a fill, outline, or style reference.
    private func color(_ element: XMLElement?) -> String? {
        if let rgb = element?.child("srgbClr", in: OOXMLNamespace.a)?.attribute(forName: "val")?.stringValue {
            return "#\(rgb)"
        }
        return element?.child("schemeClr", in: OOXMLNamespace.a)?.attribute(forName: "val")?.stringValue.flatMap(theme.color)
    }

    private static func emu(_ element: XMLElement?, _ attribute: String) -> Double? {
        emu(element?.attribute(forName: attribute)?.stringValue)
    }

    private static func emu(_ text: String?) -> Double? {
        text.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { $0 / 12700 }
    }

    /// Writes into a fresh buffer and returns it, for content nested inside a cell or shape.
    private mutating func rendering(_ body: (inout DocxHTMLWriter) -> Void) -> String {
        let saved = html
        html = ""
        body(&self)
        let content = html
        html = saved
        return content
    }

    /// Pre-2010 VML pictures: `<v:imagedata r:id>` inside `<v:shape style="width:…;height:…">`.
    private func vmlImage(_ pict: XMLElement) -> String {
        guard let data = pict.firstDescendant("imagedata", in: OOXMLNamespace.v),
              let id = data.value("id", in: OOXMLNamespace.r) else { return "" }
        let shapeStyle = pict.firstDescendant("shape", in: OOXMLNamespace.v)?.attribute(forName: "style")?.stringValue ?? ""
        let size = shapeStyle.split(separator: ";").filter { $0.hasPrefix("width") || $0.hasPrefix("height") }.map(String.init)
        return imageTag(relationship: id, css: size)
    }

    private func imageTag(relationship id: String, css: [String]) -> String {
        let style = css.joined(separator: ";")
        guard let uri = dataURI(relationship: id) else {
            // Unsupported formats (EMF, WMF) keep their space so the layout does not shift.
            return #"<span class="missing-image" style="display:inline-block;\#(style)"></span>"#
        }
        return #"<img src="\#(uri)" style="\#(style)">"#
    }

    /// The related image as a `data:` URL, for the formats WebKit draws.
    private func dataURI(relationship id: String) -> String? {
        guard let path = relationships[id],
              let mime = Self.imageTypes[URL(filePath: path).pathExtension.lowercased()],
              let data = try? package.data(at: path) else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static let imageTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff", "svg": "image/svg+xml",
    ]

    // MARK: - Tables

    private struct Cell {
        var element: XMLElement
        var column: Int
        var span: Int
        var rowSpan = 1
        var isContinuation: Bool
    }

    private mutating func table(_ tbl: XMLElement) {
        let tblPr = tbl.child("tblPr")
        let tableStyle = tblPr?.child("tblStyle")?.value()
        let tableBorders = styles.tableBorders(styleID: tableStyle)
            .merging(borders(tblPr?.child("tblBorders"))) { $1 }
        let grid = tbl.child("tblGrid")?.children("gridCol").map { twips($0.number("w") ?? 0) } ?? []
        // Word's default cell margins: 0.075 inch at the sides, none above and below.
        let cellMargins = Self.cellMargins(tblPr?.child("tblCellMar"), default: ["top": 0, "right": 5.4, "bottom": 0, "left": 5.4])

        var rows: [[Cell]] = []
        var heights: [String?] = []
        for tr in tbl.children("tr") {
            var column = Int(tr.child("trPr")?.child("gridBefore")?.number() ?? 0)
            var cells: [Cell] = []
            for tc in Self.cells(of: tr) {
                let tcPr = tc.child("tcPr")
                let span = Int(tcPr?.child("gridSpan")?.number() ?? 1)
                let vMerge = tcPr?.child("vMerge")
                let isContinuation = vMerge != nil && vMerge?.value() != "restart"
                if isContinuation {
                    Self.extendRowSpan(in: &rows, column: column)
                }
                cells.append(Cell(element: tc, column: column, span: span, isContinuation: isContinuation))
                column += span
            }
            rows.append(cells)
            heights.append(tr.child("trPr")?.child("trHeight")?.number().map { "height:\(decimal(twips($0)))pt" })
        }

        var css = ["table-layout:fixed"]
        if !grid.isEmpty {
            css.append("width:\(decimal(grid.reduce(0, +)))pt")
        }
        switch tblPr?.child("jc")?.value() {
        case "center": css.append("margin-left:auto;margin-right:auto")
        case "right", "end": css.append("margin-left:auto")
        default:
            if let indent = tblPr?.child("tblInd")?.number("w") {
                css.append("margin-left:\(decimal(twips(indent)))pt")
            }
        }

        html += #"<table style="\#(css.joined(separator: ";"))"><colgroup>"#
        html += grid.map { #"<col style="width:\#(decimal($0))pt">"# }.joined()
        html += "</colgroup>\n"
        for (rowIndex, row) in rows.enumerated() {
            html += "<tr\(heights[rowIndex].map { #" style="\#($0)""# } ?? "")>"
            for cell in row where !cell.isContinuation {
                let saved = tableCellFormat
                tableCellFormat = styles.tableCellFormat(styleID: tableStyle)
                defer { tableCellFormat = saved }
                html += tableCell(cell, row: rowIndex, rowCount: rows.count, columnCount: grid.count, tableBorders: tableBorders, margins: cellMargins)
            }
            html += "</tr>\n"
        }
        html += "</table>\n"
    }

    /// `w:tblCellMar` or `w:tcMar` in points by side, over `defaults`.
    private static func cellMargins(_ element: XMLElement?, default defaults: [String: Double]) -> [String: Double] {
        var margins = defaults
        for (side, names) in [("top", ["top"]), ("right", ["right", "end"]), ("bottom", ["bottom"]), ("left", ["left", "start"])] {
            if let width = names.lazy.compactMap({ element?.child($0)?.number("w") }).first { margins[side] = twips(width) }
        }
        return margins
    }

    private mutating func tableCell(
        _ cell: Cell, row: Int, rowCount: Int, columnCount: Int, tableBorders: Borders, margins tableMargins: [String: Double]
    ) -> String {
        let tcPr = cell.element.child("tcPr")
        let margins = Self.cellMargins(tcPr?.child("tcMar"), default: tableMargins)
        let outer = [
            "top": row == 0,
            "bottom": row + cell.rowSpan >= rowCount,
            "left": cell.column == 0,
            "right": cell.column + cell.span >= columnCount,
        ]
        let inner = ["top": "insideH", "bottom": "insideH", "left": "insideV", "right": "insideV"]
        let cellBorders = borders(tcPr?.child("tcBorders"))
        var css: [String] = []
        for side in ["top", "right", "bottom", "left"] {
            let fromTable = tableBorders[outer[side] == true ? side : inner[side]!] ?? nil
            let border = cellBorders[side] ?? fromTable
            css.append("border-\(side):\(border?.css ?? "none")")
        }
        if let fill = tcPr?.child("shd")?.value("fill"), fill != "auto" {
            css.append("background:#\(fill)")
        }
        switch tcPr?.child("vAlign")?.value() {
        case "center": css.append("vertical-align:middle")
        case "bottom": css.append("vertical-align:bottom")
        default: break
        }

        css.append("padding:" + ["top", "right", "bottom", "left"].map { "\(decimal(margins[$0] ?? 0))pt" }.joined(separator: " "))
        let content = rendering { $0.blocks(cell.element.elements) }

        var attributes = tcPr?.child("noWrap")?.isOn == true ? #" class="nowrap""# : ""
        if cell.span > 1 { attributes += #" colspan="\#(cell.span)""# }
        if cell.rowSpan > 1 { attributes += #" rowspan="\#(cell.rowSpan)""# }
        return #"<td\#(attributes) style="\#(css.joined(separator: ";"))">\#(content)</td>"#
    }

    private static func cells(of tr: XMLElement) -> [XMLElement] {
        tr.elements.flatMap { element -> [XMLElement] in
            switch element.localName {
            case "tc": [element]
            case "sdt", "customXml": element.child("sdtContent").map(cells(of:)) ?? []
            default: []
            }
        }
    }

    /// A `vMerge` continuation grows the cell that started the merge in the same column.
    private static func extendRowSpan(in rows: inout [[Cell]], column: Int) {
        for rowIndex in rows.indices.reversed() {
            guard let cellIndex = rows[rowIndex].firstIndex(where: { $0.column == column }) else { return }
            if !rows[rowIndex][cellIndex].isContinuation {
                rows[rowIndex][cellIndex].rowSpan += 1
                return
            }
        }
    }

    // MARK: - CSS

    private func paragraphCSS(_ format: ParagraphFormat, run: RunFormat, isEmpty: Bool) -> [String] {
        var css: [String] = []
        switch format.alignment {
        case "center": css.append("text-align:center")
        case "right", "end": css.append("text-align:right")
        case "both", "distribute": css.append("text-align:justify")
        default: break
        }
        if let left = format.indentLeft, left != 0 { css.append("margin-left:\(decimal(left))pt") }
        if let right = format.indentRight, right != 0 { css.append("margin-right:\(decimal(right))pt") }
        if let first = format.firstLine, first != 0 { css.append("text-indent:\(decimal(first))pt") }
        // Word adds spacing after and before; CSS margins would collapse to the larger one.
        if let before = format.spaceBefore, before != 0 { css.append("padding-top:\(decimal(before))pt") }
        if let after = format.spaceAfter, after != 0 { css.append("padding-bottom:\(decimal(after))pt") }
        if let shading = format.shading { css.append("background:\(shading)") }
        // The paragraph mark's font sets the height of empty lines only; otherwise the runs do, and a
        // zero line height keeps the paragraph's own font from propping lines up.
        css += runCSS(run).filter { $0.hasPrefix("font-size") || $0.hasPrefix("font-family") }
        css.append(isEmpty ? lineHeightCSS(run) : "line-height:0")
        return css
    }

    private func lineHeightCSS(_ run: RunFormat) -> String {
        let single = singleLineHeight(run)
        return switch lineSpacing {
        case .multiple(let factor): "line-height:\(decimal(factor * single))"
        case .exactly(let points): "line-height:\(decimal(points))pt"
        case .atLeast(let points): "line-height:max(\(decimal(points))pt,\(decimal(single))em)"
        case nil: "line-height:\(decimal(single))"
        }
    }

    /// Word's "single" spacing in em: the tallest font on the line sets it.
    private func singleLineHeight(_ run: RunFormat) -> Double {
        [theme.font(run.latinFont), theme.font(run.eastAsiaFont)]
            .compactMap { $0.flatMap { Self.singleLineHeights[$0] ?? fonts.singleLineHeights[$0] } }
            .max() ?? 1.2
    }

    /// Fonts Word lays out differently from their metrics, or that are rarely embedded.
    /// Malgun Gothic is measured from Word 16 for Mac output (its win metrics say 1.33);
    /// the rest are the fonts' win metrics.
    private static let singleLineHeights: [String: Double] = {
        var table: [String: Double] = [:]
        for name in ["맑은 고딕", "Malgun Gothic"] { table[name] = 1.72 }
        for name in ["Calibri", "Calibri Light"] { table[name] = 1.22 }
        table["Times New Roman"] = 1.11
        table["Arial"] = 1.12
        return table
    }()

    private func runCSS(_ format: RunFormat) -> [String] {
        var css: [String] = []
        if format.bold == true { css.append("font-weight:bold") }
        if format.italic == true { css.append("font-style:italic") }
        let decorations = [format.underline == true ? "underline" : nil, format.strike == true ? "line-through" : nil].compactMap { $0 }
        if !decorations.isEmpty { css.append("text-decoration:\(decorations.joined(separator: " "))") }
        if let color = format.color { css.append("color:\(color)") }
        if let highlight = format.highlight { css.append("background:\(highlight)") }
        let size = format.sizePt ?? 10
        switch format.verticalAlign {
        case "superscript": css += ["font-size:\(decimal(size * 0.65))pt", "vertical-align:super"]
        case "subscript": css += ["font-size:\(decimal(size * 0.65))pt", "vertical-align:sub"]
        default: css.append("font-size:\(decimal(size))pt")
        }
        css.append("font-family:\(fontFamily(format))")
        css.append(lineHeightCSS(format))
        return css
    }

    private func fontFamily(_ format: RunFormat) -> String {
        var names: [String] = []
        for name in [theme.font(format.latinFont), theme.font(format.eastAsiaFont)].compactMap({ $0 }) {
            names.append(name)
            names += Self.fontSubstitutes[name] ?? []
        }
        names += ["Apple SD Gothic Neo"]
        var seen: Set<String> = []
        let unique = names.filter { seen.insert($0).inserted }
        // Single quotes: these lists go inside double-quoted style attributes.
        return (unique.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" } + ["sans-serif"]).joined(separator: ",")
    }

    /// Windows and Hangul fonts that macOS lacks, mapped to the closest bundled face.
    private static let fontSubstitutes: [String: [String]] = {
        var table: [String: [String]] = [:]
        for name in ["맑은 고딕", "Malgun Gothic", "굴림", "Gulim", "굴림체", "GulimChe", "돋움", "Dotum", "돋움체", "DotumChe", "함초롬돋움", "HCR Dotum", "나눔고딕", "NanumGothic"] {
            table[name] = ["Apple SD Gothic Neo"]
        }
        // AppleMyungjo draws U+005C as ₩, so Latin falls back to a serif with a real backslash first.
        for name in ["바탕", "Batang", "바탕체", "BatangChe", "궁서", "Gungsuh", "함초롬바탕", "HCR Batang", "나눔명조", "NanumMyeongjo"] {
            table[name] = ["Times New Roman", "AppleMyungjo"]
        }
        for name in ["Calibri", "Calibri Light", "Segoe UI", "Tahoma", "Verdana"] {
            table[name] = ["Helvetica Neue"]
        }
        table["Cambria"] = ["Georgia"]
        table["Consolas"] = ["Menlo"]
        table["Courier New"] = ["Courier"]
        return table
    }()

    private static func symbol(_ code: UInt32) -> String {
        // Symbol/Wingdings code points are often written in the F0xx private range.
        let mapped: UInt32 = (0xF000...0xF0FF).contains(code) ? code - 0xF000 : code
        return UnicodeScalar(mapped).map(String.init) ?? ""
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Document

    /// Splits each multi-column section's blocks into pages of side-by-side columns, filled one
    /// after another as Word does. A block taller than what is left of a column starts the next.
    /// Runs on the laid-out page, before printing.
    static let columnScript = """
    (() => {
      const ruler = document.createElement('div');
      ruler.style.height = '100pt';
      document.body.appendChild(ruler);
      const pt = ruler.getBoundingClientRect().height / 100;
      ruler.remove();
      for (const section of document.querySelectorAll('.section[data-columns]')) {
        // Widths come in points: the page is laid out again for printing, at another width in pixels.
        const count = +section.dataset.columns, gap = +section.dataset.gap, width = +section.dataset.width;
        const height = (+section.dataset.height - 2) * pt;
        section.style.width = width + 'pt';
        const blocks = [...section.children];
        const tops = blocks.map(b => b.getBoundingClientRect().top);
        const end = section.getBoundingClientRect().bottom;
        const heights = blocks.map((b, i) => (i + 1 < blocks.length ? tops[i + 1] : end) - tops[i]);
        section.style.width = '';
        const pages = [];
        let column = null, used = 0;
        const newPage = () => {
          const page = document.createElement('div');
          page.style.cssText = 'display:flex;align-items:flex-start;gap:' + gap + 'pt;height:' + (height / pt) + 'pt;overflow:hidden';
          if (pages.length) page.style.breakBefore = 'page';
          pages.push(page);
          return page;
        };
        const newColumn = () => {
          let page = pages[pages.length - 1];
          if (!page || page.children.length >= count) page = newPage();
          column = document.createElement('div');
          column.style.cssText = 'flex:none;position:relative;width:' + width + 'pt';
          if (section.dataset.separator && page.children.length) {
            column.style.borderLeft = '0.5pt solid #000';
            column.style.marginLeft = (-gap / 2) + 'pt';
            column.style.paddingLeft = (gap / 2) + 'pt';
          }
          page.appendChild(column);
          used = 0;
        };
        newColumn();
        blocks.forEach((block, i) => {
          // A page break inside the columns starts a new page; the columns carry the break themselves.
          if (block.style.breakBefore === 'page' && used > 0) { newPage(); newColumn(); }
          else if (used > 0 && used + heights[i] > height) newColumn();
          block.style.breakBefore = '';
          column.appendChild(block);
          used += heights[i];
          if (block.querySelector('[data-column-break]')) newColumn();
        });
        section.replaceChildren(...pages);
      }
    })();
    """

    static func pageSetup(_ sectPr: XMLElement?) -> PagedPDFRenderer.PageSetup {
        guard let sectPr else { return .a4 }
        var page = PagedPDFRenderer.PageSetup.a4
        if let size = sectPr.child("pgSz"), let width = size.number("w"), let height = size.number("h") {
            page.paperSize = CGSize(width: twips(width), height: twips(height))
        }
        if let margins = sectPr.child("pgMar") {
            page.margins = .init(
                top: twips(abs(margins.number("top") ?? 1440)),
                left: twips(margins.number("left") ?? 1440),
                bottom: twips(abs(margins.number("bottom") ?? 1440)),
                right: twips(margins.number("right") ?? 1440)
            )
        }
        return page
    }

    static func document(_ body: String, fontFaces: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        \(fontFaces)
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        body { margin: 0; }
        .p { margin: 0; position: relative; white-space: pre-wrap; overflow-wrap: break-word; }
        table { border-collapse: collapse; }
        td { padding: 0 5.4pt; vertical-align: top; overflow-wrap: anywhere; }
        td.nowrap .p { white-space: pre; }
        .tab { display: inline-block; min-width: 36pt; }
        .label { display: inline-block; text-indent: 0; }
        img { vertical-align: bottom; }
        /* Anything past the column would widen the document, and WebKit then shrinks every page to fit.
           Clipping only sideways lets footers hang below their page block. */
        .page { overflow-x: clip; }
        </style></head><body><div class="page">
        \(body)</div></body></html>
        """
    }
}
